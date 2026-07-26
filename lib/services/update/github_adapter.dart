import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/models/emulator.dart';
import '../../data/models/version_info.dart';
import 'version_adapter.dart';

/// 基于 GitHub Releases 的版本适配器。
///
/// 适用于 [Emulator.sourceType] 为 `github` 的模拟器。
///
/// **核心策略**（按优先级）：
///
/// 1. **重定向法（主）**：请求 `https://github.com/owner/repo/releases/latest`，
///    GitHub 会 302 重定向到 `https://github.com/owner/repo/releases/tag/v1.2.3`，
///    从重定向 Location 头直接提取版本号。**不消耗 API 配额**。
///
/// 2. **API releases 列表**：当重定向目标是 `/releases`（无 latest 标记）时，
///    请求 `releases?per_page=1` 取最新一条 release。消耗 1 次 API 配额。
///
/// 3. **API tags**：仓库完全没有 release 时，从 `tags?per_page=1` 取最新 tag。
///    消耗 1 次 API 配额。
///
/// 仅策略 2 和 3 消耗 GitHub API 匿名配额（60 次/小时），策略 1 完全不限流。
class GitHubReleasesAdapter implements VersionAdapter {
  GitHubReleasesAdapter({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 15),
                headers: {
                  'Accept': 'application/vnd.github+json',
                  'X-GitHub-Api-Version': '2022-11-28',
                },
              ),
            );

  final Dio _dio;

  @override
  String get adapterName => 'github';

  @override
  Future<VersionInfo?> fetchLatestVersion(Emulator emulator) async {
    final parsed = _parseRepo(emulator.sourceUrl);
    if (parsed == null) return null;
    final (owner, repo) = parsed;

    // 策略 1：重定向法（不消耗 API 配额）
    final redirectResult = await _fetchViaRedirect(emulator, owner, repo);
    if (redirectResult != null) return redirectResult;

    // 策略 2：API releases 列表（消耗 1 次配额）
    final listResult = await _fetchFromApiReleasesList(emulator, owner, repo);
    if (listResult != null) return listResult;

    // 策略 3：API tags（消耗 1 次配额）
    return _fetchFromTags(emulator, owner, repo);
  }

  /// 重定向法：请求 releases/latest 页面，从 302 重定向 URL 提取版本号。
  ///
  /// 返回 `null` 的情况：
  /// - 重定向到 `/releases`（有 releases 但无 latest 标记）→ 需要策略 2
  /// - 返回 404（完全无 releases）→ 需要策略 3
  /// - 网络错误
  ///
  /// 成功时，同时构造 `releases/latest/download/` 形式的动态下载链接，
  /// 写入 [VersionInfo.downloadUrl]。该链接会自动指向最新版本的 asset。
  Future<VersionInfo?> _fetchViaRedirect(
    Emulator emulator,
    String owner,
    String repo,
  ) async {
    try {
      final response = await _dio.get(
        'https://github.com/$owner/$repo/releases/latest',
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
        ),
      );

      final location = response.headers.value('location');
      if (location == null || location.isEmpty) return null;

      // 从重定向 URL 提取 tag：.../releases/tag/v1.2.3
      final tagMatch = RegExp(r'/releases/tag/(.+?)(?:\?|#|$)').firstMatch(location);
      if (tagMatch == null) {
        // 重定向到 /releases（无 tag）→ 返回 null 让策略 2 处理
        return null;
      }

      final tag = tagMatch.group(1)!;
      if (tag.isEmpty) return null;

      final version = _stripVPrefix(tag);
      if (version.isEmpty) return null;

      // 构造动态下载链接：如果静态 downloadUrl 中包含 asset 名称，
      // 则替换版本号为 latest/download 形式
      final dynamicDownloadUrl = _buildDynamicDownloadUrl(
        emulator, owner, repo, tag,
      );

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: DateTime.now(),
        releaseNotes: null,
        isNew: false,
        downloadUrl: dynamicDownloadUrl,
      );
    } catch (_) {
      return null;
    }
  }

  /// API 法：请求 releases 列表，取第一条。
  ///
  /// 适用于仓库有 releases 但没有 "latest" 标记的情况（所有都是 prerelease）。
  /// 消耗 1 次 GitHub API 匿名配额。
  ///
  /// 同时从 release 的 `assets` 数组中提取 APK 直链下载地址，
  /// 写入 [VersionInfo.downloadUrl]，供 UI 层动态使用。
  Future<VersionInfo?> _fetchFromApiReleasesList(
    Emulator emulator,
    String owner,
    String repo,
  ) async {
    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$owner/$repo/releases?per_page=1',
      );
      final list = _asList(response.data);
      if (list.isEmpty) return null;

      final first = _asMap(list.first);
      final tag = first['tag_name']?.toString();
      if (tag == null || tag.isEmpty) return null;

      final version = _stripVPrefix(tag);
      final releaseDate = _parseDate(first['published_at']?.toString());
      final body = first['body']?.toString();

      // 从 assets 数组中提取 APK 直链
      final apkUrl = _extractApkAssetUrl(first);

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: releaseDate ?? DateTime.now(),
        releaseNotes: body,
        isNew: false,
        downloadUrl: apkUrl,
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 404) return null; // 无 releases，交给策略 3
      // 403 限流 → 返回 null
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 回退方案：从 tags 接口取第一个 tag 作为最新版本。
  Future<VersionInfo?> _fetchFromTags(
    Emulator emulator,
    String owner,
    String repo,
  ) async {
    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$owner/$repo/tags?per_page=1',
      );
      final list = _asList(response.data);
      if (list.isEmpty) return null;

      final first = _asMap(list.first);
      final tag = first['name']?.toString();
      if (tag == null || tag.isEmpty) return null;

      final version = _stripVPrefix(tag);

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: DateTime.now(),
        releaseNotes: null,
        isNew: false,
      );
    } catch (_) {
      return null;
    }
  }

  /// 从 GitHub 仓库 URL 解析出 (owner, repo)。
  (String, String)? _parseRepo(String sourceUrl) {
    if (sourceUrl.isEmpty) return null;
    try {
      final uri = Uri.parse(sourceUrl);
      if (!uri.host.contains('github.com')) return null;
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length < 2) return null;
      final owner = segments[0];
      var repo = segments[1];
      if (repo.endsWith('.git')) {
        repo = repo.substring(0, repo.length - 4);
      }
      return (owner, repo);
    } catch (_) {
      return null;
    }
  }

  /// 从 release 的 `assets` 数组中提取第一个 `.apk` 文件的下载地址。
  ///
  /// GitHub API 的 release 对象包含 `assets` 数组，每个 asset 有
  /// `browser_download_url` 字段。返回第一个以 `.apk` 结尾的 URL，
  /// 优先选择 `arm64` / `aarch64` 架构的包。
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
      // 优先选择 arm64/aarch64 架构的 APK
      if (name.contains('arm64') ||
          name.contains('aarch64') ||
          name.contains('arm64-v8a')) {
        arm64Apk = url;
      }
      anyApk ??= url;
    }

    return arm64Apk ?? anyApk;
  }

  /// 构造动态下载链接。
  ///
  /// 如果模拟器的静态 [downloadUrl] 已经是 `releases/latest/download/` 形式，
  /// 直接返回（已动态）。
  /// 如果是 `releases/download/{旧版本}/{asset}` 形式，提取 asset 名称，
  /// 替换为 `releases/latest/download/{asset}` 形式（自动指向最新版）。
  /// 如果静态 URL 无法解析出 asset 名，返回 null（由 API 策略处理）。
  String? _buildDynamicDownloadUrl(
    Emulator emulator,
    String owner,
    String repo,
    String latestTag,
  ) {
    final staticUrl = emulator.downloadUrl;
    if (staticUrl.isEmpty) return null;

    // 已经是 latest/download 形式，直接返回
    if (staticUrl.contains('/releases/latest/download/')) {
      return staticUrl;
    }

    // 从 releases/download/{tag}/{asset} 中提取 asset 名称
    final versionedMatch = RegExp(
      r'/releases/download/[^/]+/(.+)$',
    ).firstMatch(staticUrl);

    if (versionedMatch != null) {
      final asset = versionedMatch.group(1);
      if (asset != null && asset.isNotEmpty) {
        return 'https://github.com/$owner/$repo/releases/latest/download/$asset';
      }
    }

    // 无法从静态 URL 解析出 asset，返回 null
    return null;
  }

  /// 去除版本号前的 `v` / `V` 前缀。
  String _stripVPrefix(String tag) {
    var v = tag.trim();
    if (v.startsWith('v') || v.startsWith('V')) {
      v = v.substring(1);
    }
    return v;
  }

  /// 解析 ISO 8601 时间字符串，失败返回 `null`。
  DateTime? _parseDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return null;
    try {
      return DateTime.parse(dateStr);
    } catch (_) {
      return null;
    }
  }

  /// 将响应体统一为 `Map<String, dynamic>`。
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

  /// 将响应体统一为 `List`。
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
