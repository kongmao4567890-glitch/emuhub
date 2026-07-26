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
/// 1. **HTML 抓取法（主）**：直接请求 `releases/latest` 页面 HTML，
///    跟随 302 重定向，从最终页面提取版本号、更新说明、APK 直链和发布日期。
///    **不消耗 GitHub API 配额，完全不限流。**
///
/// 2. **API releases 列表**：HTML 方法失败时的回退。消耗 1 次 API 配额。
///
/// 3. **API tags**：仓库无 release 时的最后回退。消耗 1 次 API 配额。
class GitHubReleasesAdapter implements VersionAdapter {
  GitHubReleasesAdapter({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 20),
                headers: {
                  'Accept': 'text/html,application/xhtml+xml',
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

    VersionInfo? result;

    // 策略 1：HTML 抓取法（不消耗 API 配额，不限流）
    result = await _fetchFromHtml(emulator, owner, repo);

    // 策略 2：API releases 列表（回退，消耗 1 次配额）
    if (result == null) {
      result = await _fetchFromApiReleasesList(emulator, owner, repo);
    }

    // 策略 3：API tags（最后回退，消耗 1 次配额）
    if (result == null) {
      result = await _fetchFromTags(emulator, owner, repo);
    }

    // 获取开发版信息（同样用 HTML，不限流）
    if (result != null && emulator.devUrl.isNotEmpty) {
      final devInfo = await _fetchPrereleaseInfoFromHtml(owner, repo);
      if (devInfo != null) {
        result = result.copyWith(
          devDownloadUrl: devInfo.apkUrl,
          devReleaseNotes: devInfo.body,
        );
      }
    }

    return result;
  }

  // ===========================================================================
  // 策略 1：HTML 抓取法（不限流）
  // ===========================================================================

  /// 直接请求 `releases/latest` 页面 HTML，跟随重定向，
  /// 从最终页面提取版本号、更新说明、APK 直链和发布日期。
  ///
  /// **不消耗 GitHub API 配额，完全不限流。**
  Future<VersionInfo?> _fetchFromHtml(
    Emulator emulator,
    String owner,
    String repo,
  ) async {
    try {
      final response = await _dio.get(
        'https://github.com/$owner/$repo/releases/latest',
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: true,
          validateStatus: (status) => status != null && status < 400,
        ),
      );

      final html = response.data.toString();
      final finalUrl = response.realUri.toString();

      // 1. 从最终 URL 提取版本号：.../releases/tag/v1.2.3
      final tagMatch =
          RegExp(r'/releases/tag/(.+?)(?:\?|#|$)').firstMatch(finalUrl);
      if (tagMatch == null) return null;
      final tag = tagMatch.group(1)!;
      if (tag.isEmpty) return null;

      final version = _stripVPrefix(tag);
      if (version.isEmpty) return null;

      // 2. 从 HTML 提取更新说明
      final releaseNotes = _extractReleaseNotesFromHtml(html);

      // 3. 从 HTML 提取 APK 下载链接
      final apkUrl = _extractApkUrlFromHtml(html);

      // 4. 从 HTML 提取发布日期
      final releaseDate = _extractReleaseDateFromHtml(html);

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: releaseDate ?? DateTime.now(),
        releaseNotes: releaseNotes,
        isNew: false,
        downloadUrl: apkUrl,
      );
    } catch (_) {
      return null;
    }
  }

  /// 从 HTML 中提取更新说明。
  ///
  /// GitHub releases 页面中，更新说明位于 `<div class="markdown-body">` 中。
  /// 使用 div 嵌套计数法正确处理嵌套标签。
  String? _extractReleaseNotesFromHtml(String html) {
    // 找到 markdown-body div 的开始标签
    final startPattern = RegExp(
      r'<div[^>]*class="[^"]*markdown-body[^"]*"[^>]*>',
    );
    final startMatch = startPattern.firstMatch(html);
    if (startMatch == null) return null;

    final contentStart = startMatch.end;

    // 用 div 嵌套计数找到匹配的 </div>
    var depth = 1;
    var pos = contentStart;
    final tagPattern = RegExp(r'<(/?)div\b[^>]*>');

    while (depth > 0 && pos < html.length) {
      final match = tagPattern.firstMatch(html.substring(pos));
      if (match == null) break;

      final isClosing = match.group(1) == '/';
      if (isClosing) {
        depth--;
      } else {
        depth++;
      }

      if (depth == 0) {
        final content = html.substring(contentStart, pos + match.start);
        return _cleanHtml(content);
      }

      pos += match.end;
    }

    return null;
  }

  /// 从 HTML 中提取 APK 下载链接。
  ///
  /// 匹配 href 中包含 `.apk` 的链接，优先选择 arm64/aarch64 架构的包。
  String? _extractApkUrlFromHtml(String html) {
    final pattern = RegExp(r'href="(/[^"]*\.apk)"');
    final matches = pattern.allMatches(html);

    String? arm64Apk;
    String? anyApk;

    for (final match in matches) {
      final path = match.group(1)!;
      final url =
          path.startsWith('http') ? path : 'https://github.com$path';
      final name = path.toLowerCase();

      if (name.contains('arm64') ||
          name.contains('aarch64') ||
          name.contains('arm64-v8a')) {
        arm64Apk ??= url;
      }
      anyApk ??= url;
    }

    return arm64Apk ?? anyApk;
  }

  /// 从 HTML 中提取发布日期。
  ///
  /// 尝试 `<relative-time datetime="...">` 或 `<time datetime="...">`。
  DateTime? _extractReleaseDateFromHtml(String html) {
    // <relative-time datetime="2026-07-21T20:38:00Z">
    final relTimeMatch = RegExp(
      r'<relative-time[^>]*datetime="([^"]+)"',
    ).firstMatch(html);
    if (relTimeMatch != null) {
      return _parseDate(relTimeMatch.group(1));
    }

    // <time datetime="2026-07-21T20:38:00Z">
    final timeMatch = RegExp(
      r'<time[^>]*datetime="([^"]+)"',
    ).firstMatch(html);
    if (timeMatch != null) {
      return _parseDate(timeMatch.group(1));
    }

    return null;
  }

  /// 清理 HTML，转换为纯文本（保留基本格式）。
  String _cleanHtml(String html) {
    var result = html;
    // 块级标签转换为换行
    result = result.replaceAll(RegExp(r'<br\s*/?>'), '\n');
    result = result.replaceAll(RegExp(r'</p>'), '\n\n');
    result = result.replaceAll(RegExp(r'</h[1-6]>'), '\n\n');
    result = result.replaceAll(RegExp(r'<li[^>]*>'), '\n• ');
    result = result.replaceAll(RegExp(r'</li>'), '');
    // 链接转换为 markdown 格式
    result = result.replaceAllMapped(
      RegExp(r'<a[^>]*href="([^"]*)"[^>]*>(.*?)</a>', dotAll: true),
      (m) => '[${m.group(2)}](${m.group(1)})',
    );
    // 移除所有其他 HTML 标签
    result = result.replaceAll(RegExp(r'<[^>]+>'), '');
    // 解码 HTML 实体
    result = result.replaceAll('&lt;', '<');
    result = result.replaceAll('&gt;', '>');
    result = result.replaceAll('&amp;', '&');
    result = result.replaceAll('&#39;', "'");
    result = result.replaceAll('&apos;', "'");
    result = result.replaceAll('&quot;', '"');
    result = result.replaceAll('&nbsp;', ' ');
    result = result.replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (m) => String.fromCharCode(int.parse(m.group(1)!)),
    );
    // 压缩多余空行
    result = result.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return result.trim();
  }

  /// 从 releases 列表页面 HTML 获取开发版（prerelease）信息。
  ///
  /// **不消耗 API 配额，不限流。**
  Future<({String? apkUrl, String? body})?> _fetchPrereleaseInfoFromHtml(
    String owner,
    String repo,
  ) async {
    try {
      final response = await _dio.get(
        'https://github.com/$owner/$repo/releases',
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: true,
          validateStatus: (status) => status != null && status < 400,
        ),
      );

      final html = response.data.toString();

      // 找到 "Pre-release" 标记
      final preReleaseIdx = html.indexOf(
        RegExp(r'Pre-release', caseSensitive: false),
      );
      if (preReleaseIdx < 0) return null;

      // 从 Pre-release 标记后提取信息
      final afterPreRelease = html.substring(preReleaseIdx);
      final releaseNotes = _extractReleaseNotesFromHtml(afterPreRelease);
      final apkUrl = _extractApkUrlFromHtml(afterPreRelease);

      if (apkUrl == null && releaseNotes == null) return null;

      return (apkUrl: apkUrl, body: releaseNotes);
    } catch (_) {
      return null;
    }
  }

  // ===========================================================================
  // 策略 2-3：API 回退（仅在 HTML 方法失败时使用）
  // ===========================================================================

  /// API 法：请求 releases 列表，取第一条。
  Future<VersionInfo?> _fetchFromApiReleasesList(
    Emulator emulator,
    String owner,
    String repo,
  ) async {
    try {
      final apiDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
        },
      ));

      final response = await apiDio.get(
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
      final apkUrl = _extractApkAssetUrl(first);

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: releaseDate ?? DateTime.now(),
        releaseNotes: body,
        isNew: false,
        downloadUrl: apkUrl,
      );
    } catch (_) {
      return null;
    }
  }

  /// 回退方案：从 tags 接口取第一个 tag。
  Future<VersionInfo?> _fetchFromTags(
    Emulator emulator,
    String owner,
    String repo,
  ) async {
    try {
      final apiDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
        },
      ));

      final response = await apiDio.get(
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

  // ===========================================================================
  // 辅助方法
  // ===========================================================================

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

  /// 从 release 的 `assets` 数组中提取 APK 直链（用于 API 回退）。
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
      anyApk ??= url;
    }

    return arm64Apk ?? anyApk;
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
