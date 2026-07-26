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
  Future<VersionInfo?> fetchLatestVersion(Emulator emulator) async {
    final parsed = _parseProject(emulator.sourceUrl);
    if (parsed == null) return null;
    final (host, projectPath) = parsed;

    // URL 编码 project path: eightbitwonders/app → eightbitwonders%2Fapp
    final encodedPath = Uri.encodeComponent(projectPath);

    try {
      final response = await _dio.get(
        'https://$host/api/v4/projects/$encodedPath/releases',
        queryParameters: {'per_page': 1},
      );

      final list = _asList(response.data);
      if (list.isEmpty) return null;

      final first = _asMap(list.first);
      final tagName = first['tag_name']?.toString();
      if (tagName == null || tagName.isEmpty) return null;

      final version = _stripVPrefix(tagName);
      final createdAt = _parseDate(first['created_at']?.toString());
      final description = first['description']?.toString();

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: createdAt ?? DateTime.now(),
        releaseNotes: (description != null && description.isNotEmpty) ? description : null,
        isNew: false,
      );
    } catch (_) {
      return null;
    }
  }

  /// 从 GitLab 仓库 URL 解析出 (host, projectPath)。
  /// 支持 `https://gitlab.com/owner/repo` 等形式。
  /// projectPath 返回 `owner/repo`。
  (String, String)? _parseProject(String sourceUrl) {
    if (sourceUrl.isEmpty) return null;
    try {
      final uri = Uri.parse(sourceUrl);
      if (!uri.host.contains('gitlab.com')) return null;
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length < 2) return null;

      // 提取 owner/repo（去掉 -/releases 等后缀）
      final owner = segments[0];
      var repo = segments[1];
      if (repo.endsWith('.git')) {
        repo = repo.substring(0, repo.length - 4);
      }
      return (uri.host, '$owner/$repo');
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
