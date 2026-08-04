import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/models/emulator.dart';
import '../../data/models/version_info.dart';
import 'version_adapter.dart';

/// 基于 Forgejo/Gitea Releases API 的版本适配器。
///
/// 适用于 [Emulator.sourceType] 为 `forgejo` 的模拟器。
///
/// Forgejo/Gitea 使用与 Gitea 兼容的 API：
/// `GET https://{host}/api/v1/repos/{owner}/{repo}/releases?limit=1`
///
/// 从 release 的 `assets` 数组中提取 APK 直链，
/// 从 `body` 字段提取更新说明，
/// 从 `tag_name` 提取版本号，
/// 从 `published_at` 提取发布日期。
///
/// 同时查找 prerelease 获取开发版信息。
class ForgejoReleasesAdapter implements VersionAdapter {
  ForgejoReleasesAdapter({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 15),
                headers: {
                  'Accept': 'application/json',
                },
              ),
            );

  final Dio _dio;

  @override
  String get adapterName => 'forgejo';

  @override
  Future<VersionInfo?> fetchLatestVersion(
    Emulator emulator, {
    bool includeDetails = false,
  }) async {
    final parsed = _parseRepo(emulator.sourceUrl);
    if (parsed == null) return null;
    final (host, owner, repo) = parsed;

    try {
      // 获取最新 release（非 prerelease）
      final response = await _dio.get(
        'https://$host/api/v1/repos/$owner/$repo/releases',
        queryParameters: {'limit': 10, 'draft': false},
      );

      final list = _asList(response.data);
      if (list.isEmpty) return null;

      // 查找第一个非 prerelease 的 release（稳定版）
      Map<String, dynamic>? stableRelease;
      Map<String, dynamic>? preRelease;

      for (final item in list) {
        final release = _asMap(item);
        final isPrerelease = release['prerelease'] == true;
        if (isPrerelease) {
          preRelease ??= release;
        } else {
          stableRelease ??= release;
        }
      }

      // 配置了开发/每夜渠道时按发布时间选择稳定版与预发布版；未配置时
      // 仍以稳定版为主，避免普通用户意外跟踪测试构建。
      var release = stableRelease ?? _asMap(list.first);
      if (preRelease != null &&
          (emulator.devUrl.isNotEmpty || emulator.nightlyUrl.isNotEmpty)) {
        final stableDate = _parseDate(release['published_at']?.toString());
        final preDate = _parseDate(preRelease['published_at']?.toString());
        if (preDate != null &&
            (stableDate == null || preDate.isAfter(stableDate))) {
          release = preRelease;
        }
      }
      if (release.isEmpty) return null;

      final tagName = release['tag_name']?.toString();
      if (tagName == null || tagName.isEmpty) return null;

      final version = _stripVPrefix(tagName);
      final publishedAt = _parseDate(release['published_at']?.toString());
      final body = await _resolveReleaseNotes(host, owner, repo, release);
      final apkUrl = _extractApkAssetUrl(release);

      // 构建开发版信息
      String? devApkUrl;
      String? devBody;
      if (preRelease != null) {
        devApkUrl = _extractApkAssetUrl(preRelease);
        devBody = await _resolveReleaseNotes(host, owner, repo, preRelease);
      }

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: publishedAt,
        releaseNotes: body,
        isNew: false,
        downloadUrl: apkUrl,
        devDownloadUrl: devApkUrl,
        devReleaseNotes: devBody,
      );
    } catch (_) {
      return null;
    }
  }

  /// 从 Forgejo 仓库 URL 解析出 (host, owner, repo)。
  ///
  /// 支持：
  /// - `https://git.eden-emu.dev/eden-emu/eden`
  /// - `https://git.example.com/owner/repo`
  (String, String, String)? _parseRepo(String sourceUrl) {
    if (sourceUrl.isEmpty) return null;
    try {
      final uri = Uri.parse(sourceUrl);
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length < 2) return null;

      final owner = segments[0];
      var repo = segments[1];
      if (repo.endsWith('.git')) {
        repo = repo.substring(0, repo.length - 4);
      }
      return (uri.host, owner, repo);
    } catch (_) {
      return null;
    }
  }

  /// 从 release 的 `assets` 数组中提取第一个 `.apk` 文件的下载地址。
  ///
  /// Forgejo/Gitea release 的 `assets` 数组中每个 asset 有
  /// `browser_download_url` 字段。优先选择 arm64/aarch64 架构的 APK。
  String? _extractApkAssetUrl(Map<String, dynamic> release) {
    final assets = release['assets'];
    if (assets is! List) return null;

    String? arm64Apk;
    String? anyApk;

    for (final asset in assets) {
      final assetMap = _asMap(asset);
      final url = assetMap['browser_download_url']?.toString();
      if (url == null || url.isEmpty) continue;
      if (!url.toLowerCase().endsWith('.apk')) continue;

      final name = (assetMap['name']?.toString() ?? '').toLowerCase();
      if (name.contains('arm64') ||
          name.contains('aarch64') ||
          name.contains('arm64-v8a')) {
        arm64Apk = url;
      }
      // 跳过 x86_64/chromeos 版本
      if (name.contains('x86') || name.contains('chromeos')) continue;
      anyApk ??= url;
    }

    return arm64Apk ?? anyApk;
  }

  String _stripVPrefix(String tag) {
    var v = tag.trim();
    if (v.startsWith('v') || v.startsWith('V')) {
      v = v.substring(1);
    }
    return v;
  }

  DateTime? _parseDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return null;
    try {
      return DateTime.parse(dateStr);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _resolveReleaseNotes(
    String host,
    String owner,
    String repo,
    Map<String, dynamic> release,
  ) async {
    final body = _nonEmptyText(release['body']);
    if (body != null) return body;

    final tag = _nonEmptyText(release['tag_name']);
    final target = _nonEmptyText(release['target_commitish']);
    final reference = tag ?? target;
    if (reference != null) {
      try {
        final response = await _dio.get(
          'https://$host/api/v1/repos/$owner/$repo/git/commits/'
          '${Uri.encodeComponent(reference)}',
        );
        final commit = _asMap(response.data);
        final nested = _asMap(commit['commit']);
        final message = _nonEmptyText(commit['message']) ??
            _nonEmptyText(nested['message']);
        if (message != null) return message;
      } catch (_) {}
    }

    final name = _nonEmptyText(release['name']);
    return name == tag ? null : name;
  }

  String? _nonEmptyText(dynamic value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return <String, dynamic>{};
  }

  List<dynamic> _asList(dynamic data) {
    if (data is List) return data;
    if (data is String && data.isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is List) return decoded;
      } catch (_) {}
    }
    return <dynamic>[];
  }
}
