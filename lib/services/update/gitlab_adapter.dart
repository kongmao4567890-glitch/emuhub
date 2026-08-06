import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/models/emulator.dart';
import '../../data/models/version_info.dart';
import 'version_adapter.dart';

/// 基于 GitLab Releases API 的版本适配器。
///
/// 适用于 [Emulator.sourceType] 为 `gitlab` 的模拟器。
///
/// GitLab API 匿名请求限制为 500 次/分钟/IP（远高于 GitHub 的 60 次/小时），
/// 因此对于 6 个 GitLab 仓库的检查不存在限流问题。
///
/// 从 [Emulator.sourceUrl]（形如 `https://gitlab.com/eightbitwonders/app`）
/// 解析出 project path，URL 编码后请求 releases 接口。
class GitLabReleasesAdapter implements VersionAdapter {
  GitLabReleasesAdapter({Dio? dio})
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
  String get adapterName => 'gitlab';

  @override
  Future<VersionInfo?> fetchLatestVersion(
    Emulator emulator, {
    bool includeDetails = false,
  }) async {
    final parsed = _parseProject(emulator.sourceUrl);
    if (parsed == null) return null;
    final (scheme, host, projectPath) = parsed;

    // URL 编码 project path: eightbitwonders/app → eightbitwonders%2Fapp
    final encodedPath = Uri.encodeComponent(projectPath);

    try {
      final response = await _dio.get(
        '$scheme://$host/api/v4/projects/$encodedPath/releases',
        queryParameters: {'per_page': 50},
      );

      final list = _asList(response.data);
      if (list.isEmpty) return null;

      // GitLab 通常按 released_at 返回，但自建实例和滚动发布项目可能重新
      // 排序。与 GitHub/Forgejo 保持一致，遍历后取发布时间最大的 release。
      Map<String, dynamic>? latest;
      DateTime? latestDate;
      for (final item in list) {
        final release = _asMap(item);
        if (release.isEmpty) continue;
        final date = _releaseDate(release);
        if (latest == null ||
            (date != null &&
                (latestDate == null || date.isAfter(latestDate)))) {
          latest = release;
          latestDate = date;
        }
      }
      final selected = latest;
      if (selected == null) return null;

      final tagName = selected['tag_name']?.toString();
      if (tagName == null || tagName.isEmpty) return null;

      final version = _stripVPrefix(tagName);
      final description = _releaseNotes(selected);

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: latestDate,
        releaseNotes: description,
        isNew: false,
      );
    } catch (_) {
      return null;
    }
  }

  /// 从 GitLab 仓库 URL 解析出 (scheme, host, projectPath)。
  /// 支持 `https://gitlab.com/owner/repo` 等形式。
  /// projectPath 保留多级 subgroup，例如 `group/subgroup/repo`。
  (String, String, String)? _parseProject(String sourceUrl) {
    if (sourceUrl.isEmpty) return null;
    try {
      final uri = Uri.parse(sourceUrl);
      if (uri.scheme != 'https' && uri.scheme != 'http') return null;
      if (uri.host.isEmpty) return null;
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length < 2) return null;

      // GitLab 页面路由从 `/-/` 开始，之前的全部段都属于项目路径。
      final routeSeparator = segments.indexOf('-');
      final projectSegments = (routeSeparator >= 0
              ? segments.take(routeSeparator)
              : segments)
          .toList();
      if (projectSegments.length < 2) return null;

      var repo = projectSegments.removeLast();
      if (repo.endsWith('.git')) {
        repo = repo.substring(0, repo.length - 4);
      }
      if (repo.isEmpty) return null;
      projectSegments.add(repo);
      return (uri.scheme, uri.host, projectSegments.join('/'));
    } catch (_) {
      return null;
    }
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

  DateTime? _releaseDate(Map<String, dynamic> release) =>
      _parseDate(release['released_at']?.toString()) ??
      _parseDate(release['created_at']?.toString());

  /// GitLab 的自动发布有时不填写 description，但 release 响应内会附带
  /// 对应 commit；使用提交 message/title 补齐更新说明。
  String? _releaseNotes(Map<String, dynamic> release) {
    final description = _nonEmptyText(release['description']);
    if (description != null) return description;

    final commit = _asMap(release['commit']);
    return _nonEmptyText(commit['message']) ?? _nonEmptyText(commit['title']);
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
