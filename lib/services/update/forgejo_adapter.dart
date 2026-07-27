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
  Future<VersionInfo?> fetchLatestVersion(Emulator emulator) async {
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

      // 优先使用稳定版，没有则用第一个 release
      final release = stableRelease ?? _asMap(list.first);
      if (release.isEmpty) return null;

      final tagName = release['tag_name']?.toString();
      if (tagName == null || tagName.isEmpty) return null;

      final version = _stripVPrefix(tagName);
      final publishedAt = _parseDate(release['published_at']?.toString());
      final body = release['body']?.toString();
      final apkUrl = _extractApkAssetUrl(release);

      // 构建开发版信息
      String? devApkUrl;
      String? devBody;
      if (preRelease != null) {
        devApkUrl = _extractApkAssetUrl(preRelease);
        devBody = preRelease['body']?.toString();
      }

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: publishedAt ?? DateTime.now(),
        releaseNotes: (body != null && body.isNotEmpty) ? body : null,
        isNew: false,
        downloadUrl: apkUrl,
        devDownloadUrl: devApkUrl,
        devReleaseNotes: (devBody != null && devBody.isNotEmpty) ? devBody : null,
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
