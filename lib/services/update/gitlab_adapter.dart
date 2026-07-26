import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

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

      // 从 assets.links 中提取 APK 直链
      final apkUrl = _extractApkAssetUrl(first);

      // 如果模拟器有 devUrl，尝试从 devUrl 仓库提取开发版 APK 直链和更新说明
      String? devApkUrl;
      String? devNotes;
      if (emulator.devUrl.isNotEmpty) {
        final devResult = await _fetchChannelApkFromGitLab(emulator.devUrl);
        devApkUrl = devResult.apkUrl;
        devNotes = devResult.releaseNotes;
      }

      // 如果模拟器有 nightlyUrl，也尝试从 nightlyUrl 仓库提取 APK 直链和更新说明
      String? nightlyApkUrl;
      String? nightlyNotes;
      if (emulator.nightlyUrl.isNotEmpty) {
        final nightlyResult =
            await _fetchChannelApkFromGitLab(emulator.nightlyUrl);
        nightlyApkUrl = nightlyResult.apkUrl;
        nightlyNotes = nightlyResult.releaseNotes;
      }

      // 如果模拟器有 previewUrl，尝试从 previewUrl 仓库提取预览版 APK 直链和更新说明
      String? previewApkUrl;
      String? previewNotes;
      if (emulator.previewUrl.isNotEmpty) {
        final previewResult =
            await _fetchChannelApkFromGitLab(emulator.previewUrl);
        previewApkUrl = previewResult.apkUrl;
        previewNotes = previewResult.releaseNotes;
      }

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: createdAt ?? DateTime.now(),
        releaseNotes: (description != null && description.isNotEmpty) ? description : null,
        isNew: false,
        downloadUrl: apkUrl,
        devDownloadUrl: devApkUrl,
        devReleaseNotes: devNotes,
        nightlyDownloadUrl: nightlyApkUrl,
        nightlyReleaseNotes: nightlyNotes,
        previewDownloadUrl: previewApkUrl,
        previewReleaseNotes: previewNotes,
      );
    } catch (_) {
      // API 失败 → 尝试 HTML 解析
      return await _fetchViaHtmlParsing(emulator, host, projectPath);
    }
  }

  /// 从 GitLab 仓库 URL 解析出 (host, projectPath)。
  /// 支持 `https://gitlab.com/owner/repo` 等形式。
  /// projectPath 返回 `owner/repo`。
  (String, String)? _parseProject(String sourceUrl) {
    if (sourceUrl.isEmpty) return null;
    try {
      final uri = Uri.parse(sourceUrl);
      // 支持 gitlab.com 和自托管 GitLab/Forgejo 实例
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

  /// 从 GitLab release 对象的 assets.links 中提取 APK 直链。
  ///
  /// GitLab API release 对象包含 `assets.links` 数组，
  /// 每个 link 有 `direct_asset_url` 或 `url` 字段。
  String? _extractApkAssetUrl(Map<String, dynamic> release) {
    final assets = release['assets'];
    if (assets is! Map) return null;
    final links = assets['links'];
    if (links is! List) return null;

    final apkPattern = RegExp(r'\.apk([?#]|$)', caseSensitive: false);

    String? arm64Apk;
    String? anyApk;

    for (final link in links) {
      final linkMap = link is Map<String, dynamic>
          ? link
          : (link is Map ? Map<String, dynamic>.from(link) : <String, dynamic>{});
      final url = (linkMap['direct_asset_url'] ?? linkMap['url'])?.toString();
      if (url == null || url.isEmpty) continue;
      if (!apkPattern.hasMatch(url)) continue;

      final name = (linkMap['name']?.toString() ?? '').toLowerCase();
      if (name.contains('arm64') ||
          name.contains('aarch64') ||
          name.contains('arm64-v8a')) {
        arm64Apk = url;
      }
      anyApk ??= url;
    }

    return arm64Apk ?? anyApk;
  }

  /// 从 GitLab 仓库 URL 提取 APK 直链和更新说明（通用渠道方法）。
  ///
  /// 适用于 devUrl / nightlyUrl / previewUrl 等渠道：
  /// 解析 URL 中的 host/projectPath，查询其 releases 列表，
  /// 遍历所有 release 找到第一个包含 APK 资产的。
  ///
  /// GitLab API 匿名请求限制为 500 次/分钟/IP，远高于 GitHub 的 60 次/小时，
  /// 因此不存在限流问题。
  Future<({String? apkUrl, String? releaseNotes})> _fetchChannelApkFromGitLab(
    String channelUrl,
  ) async {
    final parsed = _parseProject(channelUrl);
    if (parsed == null) return (apkUrl: null, releaseNotes: null);
    final (host, projectPath) = parsed;
    final encodedPath = Uri.encodeComponent(projectPath);

    try {
      final response = await _dio.get(
        'https://$host/api/v4/projects/$encodedPath/releases',
        queryParameters: {'per_page': 20},
      );
      final list = _asList(response.data);
      if (list.isEmpty) return (apkUrl: null, releaseNotes: null);

      // 遍历所有 release，找到第一个包含 APK 资产的
      for (final item in list) {
        final release = _asMap(item);
        final apkUrl = _extractApkAssetUrl(release);
        if (apkUrl != null) {
          return (
            apkUrl: apkUrl,
            releaseNotes: release['description']?.toString(),
          );
        }
      }

      return (apkUrl: null, releaseNotes: null);
    } catch (_) {
      // API 失败 → 尝试 HTML 解析
      final segments = projectPath.split('/');
      if (segments.length >= 2) {
        final owner = segments[0];
        final repo = segments[1];
        final apkUrl = await _fetchApkUrlFromGitLabHtml(host, owner, repo);
        if (apkUrl != null) {
          return (apkUrl: apkUrl, releaseNotes: null);
        }
      }
      return (apkUrl: null, releaseNotes: null);
    }
  }

  /// HTML 解析法：从 GitLab releases 页面提取 APK 下载链接。
  ///
  /// 当 API 调用失败时作为回退方案。GitLab releases 页面服务端渲染了
  /// 下载链接，可以直接从 HTML 中提取。
  Future<String?> _fetchApkUrlFromGitLabHtml(
    String host,
    String owner,
    String repo,
  ) async {
    try {
      final response = await _dio.get(
        'https://$host/$owner/$repo/-/releases',
        options: Options(
          headers: {'Accept': 'text/html'},
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final html = response.data?.toString() ?? '';
      if (html.isEmpty) return null;

      return _extractApkUrlFromGitLabHtml(html, host, owner, repo);
    } catch (_) {
      return null;
    }
  }

  /// 从 GitLab releases 页面 HTML 中提取 APK 下载链接。
  ///
  /// GitLab 的下载链接格式：
  /// - `/{owner}/{repo}/-/releases/{tag}/downloads/{asset}.apk`
  /// - `/{owner}/{repo}/uploads/{hash}/{asset}.apk`
  String? _extractApkUrlFromGitLabHtml(
    String htmlStr,
    String host,
    String owner,
    String repo,
  ) {
    try {
      final document = html_parser.parse(htmlStr);
      final links = document.querySelectorAll('a[href]');

      final apkPattern = RegExp(r'\.apk([?#]|$)', caseSensitive: false);

      String? arm64Apk;
      String? anyApk;

      for (final link in links) {
        var href = link.attributes['href'] ?? '';
        if (href.isEmpty) continue;
        if (!apkPattern.hasMatch(href)) continue;

        // 转换为完整 URL
        if (href.startsWith('/')) {
          href = 'https://$host$href';
        }

        final lower = href.toLowerCase();
        if (lower.contains('arm64') || lower.contains('aarch64')) {
          arm64Apk ??= href;
        }
        anyApk ??= href;
      }

      return arm64Apk ?? anyApk;
    } catch (_) {
      return null;
    }
  }

  /// HTML 解析法（完整版）：从 GitLab releases 页面同时提取版本号和 APK 直链。
  ///
  /// 作为 API 失败时的回退方案。
  Future<VersionInfo?> _fetchViaHtmlParsing(
    Emulator emulator,
    String host,
    String projectPath,
  ) async {
    final segments = projectPath.split('/');
    if (segments.length < 2) return null;
    final owner = segments[0];
    final repo = segments[1];

    try {
      final response = await _dio.get(
        'https://$host/$owner/$repo/-/releases',
        options: Options(
          headers: {'Accept': 'text/html'},
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final html = response.data?.toString() ?? '';
      if (html.isEmpty) return null;

      final apkUrl = _extractApkUrlFromGitLabHtml(html, host, owner, repo);

      // 从下载链接中提取版本号
      String? version;
      if (apkUrl != null) {
        final tagMatch =
            RegExp(r'/-/releases/([^/]+)/downloads/').firstMatch(apkUrl);
        if (tagMatch != null) {
          version = _stripVPrefix(tagMatch.group(1)!);
        }
      }

      // 从 HTML title 提取版本号
      if (version == null || version.isEmpty) {
        try {
          final document = html_parser.parse(html);
          final title = document.querySelector('title')?.text ?? '';
          final titleMatch = RegExp(r'([vV]?\d+[.\d]+[.\d]*)').firstMatch(title);
          if (titleMatch != null) {
            version = _stripVPrefix(titleMatch.group(1)!);
          }
        } catch (_) {}
      }

      if (version == null || version.isEmpty) return null;

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: DateTime.now(),
        releaseNotes: null,
        isNew: false,
        downloadUrl: apkUrl,
      );
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
