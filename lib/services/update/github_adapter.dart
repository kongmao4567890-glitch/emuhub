import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/models/emulator.dart';
import '../../data/models/version_info.dart';
import 'version_adapter.dart';

/// 基于 GitHub Releases 的版本适配器。
///
/// 适用于 [Emulator.sourceType] 为 `github` 的模拟器。
///
/// **核心策略**：优先使用「重定向解析法」，不经过 GitHub REST API，因此不受
/// 60 次/小时 的匿名 API 限流约束。只有当重定向法失败时才回退到 API。
///
/// 1. **重定向法（主）**：请求 `https://github.com/owner/repo/releases/latest`，
///    GitHub 会 302 重定向到 `https://github.com/owner/repo/releases/tag/v1.2.3`，
///    从重定向 Location 头直接提取版本号。无 API 限流。
/// 2. **API 法（备）**：请求 `releases/latest` 接口。可获取发布日期和更新说明，
///    但受匿名 60 次/小时限制。
/// 3. **tags 接口（兜底）**：仓库没有 release 时，从 tags 接口取最新 tag。
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

    // 策略 1：重定向法（无 API 限流）
    final redirectResult = await _fetchViaRedirect(emulator, owner, repo);
    if (redirectResult != null) {
      // 尝试用 API 补充发布日期和更新说明（即使失败也不影响版本号）
      final enriched = await _tryEnrichFromApi(emulator, owner, repo, redirectResult);
      return enriched ?? redirectResult;
    }

    // 策略 2：API releases/latest（可能触发限流）
    final apiResult = await _fetchFromApi(emulator, owner, repo);
    if (apiResult != null) return apiResult;

    // 策略 3：tags 接口兜底
    return _fetchFromTags(emulator, owner, repo);
  }

  /// 重定向法：请求 releases/latest 页面，从 302 重定向 URL 提取版本号。
  ///
  /// 此方法不经过 GitHub REST API，因此不受 60 次/小时的匿名限流约束。
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
      if (tagMatch == null) return null;

      final tag = tagMatch.group(1)!;
      if (tag.isEmpty) return null;

      final version = _stripVPrefix(tag);
      if (version.isEmpty) return null;

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

  /// 尝试用 API 补充发布日期和更新说明。失败时返回 null，不影响主流程。
  Future<VersionInfo?> _tryEnrichFromApi(
    Emulator emulator,
    String owner,
    String repo,
    VersionInfo base,
  ) async {
    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$owner/$repo/releases/latest',
      );
      final data = _asMap(response.data);
      final tag = data['tag_name']?.toString();
      if (tag == null || tag.isEmpty) return null;

      // 只有 tag 匹配时才使用 API 数据
      final apiVersion = _stripVPrefix(tag);
      if (apiVersion != base.version) return null;

      final releaseDate = _parseDate(data['published_at']?.toString());
      final body = data['body']?.toString();

      return VersionInfo(
        emulatorId: emulator.id,
        version: base.version,
        releaseDate: releaseDate ?? base.releaseDate,
        releaseNotes: body,
        isNew: false,
      );
    } catch (_) {
      return null;
    }
  }

  /// API 法：直接请求 releases/latest 接口。
  Future<VersionInfo?> _fetchFromApi(
    Emulator emulator,
    String owner,
    String repo,
  ) async {
    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$owner/$repo/releases/latest',
      );
      final data = _asMap(response.data);
      final tag = data['tag_name']?.toString();
      if (tag == null || tag.isEmpty) return null;

      final version = _stripVPrefix(tag);
      final releaseDate = _parseDate(data['published_at']?.toString());
      final body = data['body']?.toString();

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: releaseDate ?? DateTime.now(),
        releaseNotes: body,
        isNew: false,
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 404) {
        // 没有 release，调用方会继续尝试 tags
        return null;
      }
      // 403 限流或其它网络错误
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
  /// 支持 `https://github.com/owner/repo`、带尾斜杠、带 `.git` 后缀等形式。
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
      } catch (_) {
        // 忽略
      }
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
      } catch (_) {
        // 忽略
      }
    }
    return <dynamic>[];
  }
}
