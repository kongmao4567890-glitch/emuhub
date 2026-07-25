import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/models/emulator.dart';
import '../../data/models/version_info.dart';
import 'version_adapter.dart';

/// 基于 GitHub Releases API 的版本适配器。
///
/// 适用于 [Emulator.sourceType] 为 `github` 的模拟器。从 [Emulator.sourceUrl]
/// （形如 `https://github.com/libretro/RetroArch`）解析出 owner / repo，
/// 请求 `releases/latest` 接口获取最新发布版本。
///
/// 错误处理：
/// - **404**：仓库没有 release，回退到 `tags` 接口取最新 tag。
/// - **403**：触发 GitHub 限流，返回 `null`。
/// - 其它异常：返回 `null`，不抛出。
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
        // 没有 release，回退到 tags 接口
        return _fetchFromTags(emulator, owner, repo);
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
        'https://api.github.com/repos/$owner/$repo/tags',
      );
      final list = _asList(response.data);
      if (list.isEmpty) return null;

      final first = _asMap(list.first);
      final tag = first['name']?.toString();
      if (tag == null || tag.isEmpty) return null;

      final version = _stripVPrefix(tag);

      // 尝试通过 commit URL 获取提交时间作为发布时间
      DateTime? releaseDate;
      final commit = first['commit'];
      if (commit is Map<String, dynamic>) {
        final commitUrl = commit['url']?.toString();
        if (commitUrl != null && commitUrl.isNotEmpty) {
          releaseDate = await _fetchCommitDate(commitUrl);
        }
      }

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: releaseDate ?? DateTime.now(),
        releaseNotes: null,
        isNew: false,
      );
    } catch (_) {
      return null;
    }
  }

  /// 获取某次 commit 的提交时间。
  Future<DateTime?> _fetchCommitDate(String commitUrl) async {
    try {
      final response = await _dio.get(commitUrl);
      final data = _asMap(response.data);
      final commit = data['commit'];
      if (commit is Map<String, dynamic>) {
        final author = commit['author'];
        if (author is Map<String, dynamic>) {
          return _parseDate(author['date']?.toString());
        }
      }
    } catch (_) {
      // 忽略，使用默认时间
    }
    return null;
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
