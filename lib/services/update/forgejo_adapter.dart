import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

import '../../data/models/emulator.dart';
import '../../data/models/version_info.dart';
import 'version_adapter.dart';

/// 基于 Forgejo（Gitea 兼容）Releases API 的版本适配器。
///
/// 适用于 [Emulator.sourceType] 为 `forgejo` 的模拟器。
///
/// Forgejo 使用 Gitea 兼容的 REST API：
/// `https://{host}/api/v1/repos/{owner}/{repo}/releases`
///
/// 与 GitLab API 的主要差异：
/// - 端点为 `/api/v1/repos/` 而非 `/api/v4/projects/`
/// - project path 无需 URL 编码
/// - asset 结构使用 `browser_download_url` 字段
///
/// 典型用例：Eden 模拟器（git.eden-emu.dev），源码托管在自建 Forgejo 实例上。
/// 稳定版 APK 托管在 stable.eden-emu.dev，每夜版托管在 nightly.eden-emu.dev。
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
      final response = await _dio.get(
        'https://$host/api/v1/repos/$owner/$repo/releases',
        queryParameters: {'limit': 5},
      );

      final list = _asList(response.data);
      if (list.isEmpty) return null;

      // 优先选择非 prerelease 的最新 release（稳定版）
      Map<String, dynamic>? stableRelease;
      Map<String, dynamic>? prereleaseRelease;

      for (final item in list) {
        final release = _asMap(item);
        final isPrerelease = release['prerelease'] == true;
        if (!isPrerelease && stableRelease == null) {
          stableRelease = release;
        } else if (isPrerelease && prereleaseRelease == null) {
          prereleaseRelease = release;
        }
        if (stableRelease != null && prereleaseRelease != null) break;
      }

      // 如果没有非 prerelease，回退到第一个 release
      final latestRelease = stableRelease ?? _asMap(list.first);
      if (latestRelease.isEmpty) return null;

      final tagName = latestRelease['tag_name']?.toString();
      if (tagName == null || tagName.isEmpty) return null;

      final version = _stripVPrefix(tagName);
      final publishedAt = _parseDate(latestRelease['published_at']?.toString());
      final body = latestRelease['body']?.toString();

      // 从稳定版 release 提取 APK 直链
      final apkUrl = _extractApkAssetUrl(latestRelease);

      // 从 prerelease 提取开发版 APK 直链和更新说明
      String? devApkUrl;
      String? devNotes;
      if (prereleaseRelease != null) {
        devApkUrl = _extractApkAssetUrl(prereleaseRelease);
        final devBody = prereleaseRelease['body']?.toString();
        if (devBody != null && devBody.isNotEmpty) {
          devNotes = devBody;
        }
      }

      // 从 nightlyUrl 仓库提取每夜版 APK 直链和更新说明
      String? nightlyApkUrl;
      String? nightlyNotes;
      if (emulator.nightlyUrl.isNotEmpty) {
        final nightlyResult = await _fetchNightlyApkUrl(emulator.nightlyUrl);
        nightlyApkUrl = nightlyResult.apkUrl;
        nightlyNotes = nightlyResult.releaseNotes;
      }

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: publishedAt ?? DateTime.now(),
        releaseNotes: (body != null && body.isNotEmpty) ? body : null,
        isNew: false,
        downloadUrl: apkUrl,
        devDownloadUrl: devApkUrl,
        nightlyDownloadUrl: nightlyApkUrl,
        devReleaseNotes: devNotes,
        nightlyReleaseNotes: nightlyNotes,
      );
    } catch (_) {
      // API 失败 → 尝试 HTML 解析
      return await _fetchViaHtmlParsing(emulator, host, owner, repo);
    }
  }

  /// 从 nightlyUrl 对应的 Forgejo 仓库提取最新 APK 直链和更新说明。
  ///
  /// nightlyUrl 可能指向与 sourceUrl 不同的仓库（如 Eden 的 CI 仓库）。
  /// 解析 nightlyUrl 中的 host/owner/repo，查询其最新 release 的 APK asset 和 body。
  Future<({String? apkUrl, String? releaseNotes})> _fetchNightlyApkUrl(
    String nightlyUrl,
  ) async {
    final parsed = _parseRepo(nightlyUrl);
    if (parsed == null) return (apkUrl: null, releaseNotes: null);
    final (host, owner, repo) = parsed;

    try {
      final response = await _dio.get(
        'https://$host/api/v1/repos/$owner/$repo/releases',
        queryParameters: {'limit': 1},
      );

      final list = _asList(response.data);
      if (list.isEmpty) return (apkUrl: null, releaseNotes: null);

      final first = _asMap(list.first);
      return (
        apkUrl: _extractApkAssetUrl(first),
        releaseNotes: first['body']?.toString(),
      );
    } catch (_) {
      // API 失败 → 尝试 HTML 解析
      final apkUrl = await _fetchApkUrlFromForgejoHtml(host, owner, repo);
      return (apkUrl: apkUrl, releaseNotes: null);
    }
  }

  /// 从 Forgejo release 对象的 assets 数组中提取 APK 直链。
  ///
  /// Forgejo/Gitea API 的 release 对象包含 `assets` 数组，
  /// 每个 asset 有 `browser_download_url` 和 `name` 字段。
  ///
  /// APK 选择优先级：
  /// 1. 名称含 `standard` 的 APK（最通用版本）
  /// 2. 名称含 `arm64` / `aarch64` 的 APK
  /// 3. 任意 APK（回退）
  String? _extractApkAssetUrl(Map<String, dynamic> release) {
    final assets = release['assets'];
    if (assets is! List) return null;

    String? standardApk;
    String? arm64Apk;
    String? anyApk;

    for (final asset in assets) {
      final assetMap = _asMap(asset);
      final url = assetMap['browser_download_url']?.toString();
      if (url == null || url.isEmpty) continue;
      if (!url.toLowerCase().endsWith('.apk')) continue;

      final name = (assetMap['name']?.toString() ?? '').toLowerCase();

      // 排除 chromeos / legacy / optimized 变体（除非没有其他选择）
      final isVariant = name.contains('chromeos') ||
          name.contains('legacy') ||
          name.contains('optimized');

      if (name.contains('standard') && !isVariant) {
        standardApk = url;
      }
      if (name.contains('arm64') ||
          name.contains('aarch64') ||
          name.contains('arm64-v8a')) {
        if (!isVariant) arm64Apk ??= url;
      }
      anyApk ??= url;
    }

    return standardApk ?? arm64Apk ?? anyApk;
  }

  /// HTML 解析法：从 Forgejo releases 页面提取 APK 下载链接。
  ///
  /// 当 API 调用失败时作为回退方案。
  Future<String?> _fetchApkUrlFromForgejoHtml(
    String host,
    String owner,
    String repo,
  ) async {
    try {
      final response = await _dio.get(
        'https://$host/$owner/$repo/releases',
        options: Options(
          headers: {'Accept': 'text/html'},
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final html = response.data?.toString() ?? '';
      if (html.isEmpty) return null;

      return _extractApkUrlFromForgejoHtml(html, host);
    } catch (_) {
      return null;
    }
  }

  /// 从 Forgejo releases 页面 HTML 中提取 APK 下载链接。
  String? _extractApkUrlFromForgejoHtml(String htmlStr, String host) {
    try {
      final document = html_parser.parse(htmlStr);
      final links = document.querySelectorAll('a[href]');

      String? arm64Apk;
      String? standardApk;
      String? anyApk;

      for (final link in links) {
        var href = link.attributes['href'] ?? '';
        if (href.isEmpty) continue;
        if (!href.toLowerCase().endsWith('.apk')) continue;
        if (!href.contains('/releases/download/')) continue;

        // 转换为完整 URL
        if (href.startsWith('/')) {
          href = 'https://$host$href';
        }

        final lower = href.toLowerCase();
        if (lower.contains('arm64') || lower.contains('aarch64')) {
          arm64Apk ??= href;
        }
        if (lower.contains('standard') || lower.contains('universal')) {
          standardApk ??= href;
        }
        anyApk ??= href;
      }

      return arm64Apk ?? standardApk ?? anyApk;
    } catch (_) {
      return null;
    }
  }

  /// HTML 解析法（完整版）：从 Forgejo releases 页面同时提取版本号和 APK 直链。
  Future<VersionInfo?> _fetchViaHtmlParsing(
    Emulator emulator,
    String host,
    String owner,
    String repo,
  ) async {
    try {
      final response = await _dio.get(
        'https://$host/$owner/$repo/releases',
        options: Options(
          headers: {'Accept': 'text/html'},
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final html = response.data?.toString() ?? '';
      if (html.isEmpty) return null;

      final apkUrl = _extractApkUrlFromForgejoHtml(html, host);

      // 从下载链接中提取版本号
      String? version;
      if (apkUrl != null) {
        final tagMatch =
            RegExp(r'/releases/download/([^/]+)/').firstMatch(apkUrl);
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

  /// 从 Forgejo 仓库 URL 解析出 (host, owner, repo)。
  ///
  /// 支持以下形式：
  /// - `https://git.eden-emu.dev/eden-emu/eden`
  /// - `https://git.eden-emu.dev/eden-emu/eden/releases`
  /// - `https://git.eden-emu.dev/eden-ci/nightly/releases`
  (String, String, String)? _parseRepo(String sourceUrl) {
    if (sourceUrl.isEmpty) return null;
    try {
      final uri = Uri.parse(sourceUrl);
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length < 2) return null;

      final owner = segments[0];
      var repo = segments[1];

      // 去掉可能的 /releases 后缀（已在 segments 中分离）
      if (repo.endsWith('.git')) {
        repo = repo.substring(0, repo.length - 4);
      }

      return (uri.host, owner, repo);
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
