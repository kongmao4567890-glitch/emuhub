import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

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
///    重定向成功后，尝试构造动态下载链接：
///    - asset 名为静态（如 `ppsspp.apk`）→ `releases/latest/download/{asset}`（免费）
///    - asset 名含版本号（如 `ARMSX2-2.6.5.2.apk`）→ 调用 API 获取真实直链（1 次配额）
///
/// 2. **API releases 列表**：当重定向目标是 `/releases`（无 latest 标记）时，
///    请求 `releases?per_page=1` 取最新一条 release。消耗 1 次 API 配额。
///
/// 3. **API tags**：仓库完全没有 release 时，从 `tags?per_page=1` 取最新 tag。
///    消耗 1 次 API 配额。
///
/// 仅策略 2 和 3 消耗 GitHub API 匿名配额（60 次/小时），策略 1 完全不限流。
/// 策略 1 的 API 补充仅在 asset 名含版本号时触发，大部分模拟器不会触发。
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

    VersionInfo? result;

    // 策略 1：重定向法（不消耗 API 配额）
    result = await _fetchViaRedirect(emulator, owner, repo);

    // 策略 2：API releases 列表（消耗 1 次配额）
    if (result == null) {
      result = await _fetchFromApiReleasesList(emulator, owner, repo);
    }

    // 策略 3：API tags（消耗 1 次配额）
    if (result == null) {
      result = await _fetchFromTags(emulator, owner, repo);
    }

    // 策略 4：HTML 解析（不消耗 API 配额，API 限流时的回退方案）
    if (result == null) {
      result = await _fetchViaHtmlParsing(emulator, owner, repo);
    }

    // 如果成功获取到版本信息，且模拟器有 devUrl，尝试获取 prerelease APK 直链和更新说明
    if (result != null && emulator.devUrl.isNotEmpty) {
      // 优先从 devUrl 解析仓库（devUrl 可能指向与 sourceUrl 不同的仓库）
      final devParsed = _parseRepo(emulator.devUrl);
      final devOwner = devParsed?.$1 ?? owner;
      final devRepo = devParsed?.$2 ?? repo;
      final devResult = await _fetchPrereleaseApkUrl(devOwner, devRepo);
      if (devResult.apkUrl != null || devResult.releaseNotes != null) {
        result = result.copyWith(
          devDownloadUrl: devResult.apkUrl,
          devReleaseNotes: devResult.releaseNotes,
        );
      }
    }

    // 如果模拟器有 nightlyUrl，尝试从 nightlyUrl 对应的仓库提取 APK 直链和更新说明
    if (result != null && emulator.nightlyUrl.isNotEmpty) {
      final nightlyResult = await _fetchNightlyApkUrl(emulator.nightlyUrl);
      if (nightlyResult.apkUrl != null ||
          nightlyResult.releaseNotes != null) {
        result = result.copyWith(
          nightlyDownloadUrl: nightlyResult.apkUrl,
          nightlyReleaseNotes: nightlyResult.releaseNotes,
        );
      }
    }

    // 如果模拟器有 previewUrl，尝试从 previewUrl 仓库提取预览版 APK 直链和更新说明
    if (result != null && emulator.previewUrl.isNotEmpty) {
      final previewResult = await _fetchPreviewApkUrl(emulator.previewUrl);
      if (previewResult.apkUrl != null ||
          previewResult.releaseNotes != null) {
        result = result.copyWith(
          previewDownloadUrl: previewResult.apkUrl,
          previewReleaseNotes: previewResult.releaseNotes,
        );
      }
    }

    return result;
  }

  /// 重定向法：请求 releases/latest 页面，从 302 重定向 URL 提取版本号。
  ///
  /// 返回 `null` 的情况：
  /// - 重定向到 `/releases`（有 releases 但无 latest 标记）→ 需要策略 2
  /// - 返回 404（完全无 releases）→ 需要策略 3
  /// - 网络错误
  ///
  /// 成功时，构造动态下载链接：
  /// - asset 名静态 → `releases/latest/download/{asset}`（免费）
  /// - asset 名含版本号 → 调用 [_fetchAssetUrlByTag] 获取真实直链（1 次配额）
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

      // 尝试构造动态下载链接
      final dynamicDownloadUrl = _buildDynamicDownloadUrl(
        emulator, owner, repo, tag,
      );

      // 如果动态链接有效（asset 名为静态），直接返回（无需 API 调用）
      if (dynamicDownloadUrl != null && dynamicDownloadUrl.isNotEmpty) {
        return VersionInfo(
          emulatorId: emulator.id,
          version: version,
          releaseDate: DateTime.now(),
          releaseNotes: null,
          isNew: false,
          downloadUrl: dynamicDownloadUrl,
        );
      }

      // 动态链接无效（asset 名含版本号）→ 用 API 获取真实 asset 直链
      var apkUrl = await _fetchAssetUrlByTag(owner, repo, tag);

      // API 失败（限流）→ 尝试 HTML 解析（不消耗配额）
      if (apkUrl == null) {
        apkUrl = await _fetchApkUrlFromHtml(owner, repo, tag: tag);
      }

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

  /// 获取最新的 prerelease（开发版/预览版）的 APK 直链和更新说明。
  ///
  /// 查询 releases 列表（per_page=30），从中筛选第一个 `prerelease=true`
  /// 且包含 APK 的 release。消耗 1 次 API 配额。
  ///
  /// 仅对配置了 devUrl 的模拟器调用，避免不必要的 API 消耗。
  /// 返回的 record 中 apkUrl 或 releaseNotes 可能为 null。
  Future<({String? apkUrl, String? releaseNotes})> _fetchPrereleaseApkUrl(
    String owner,
    String repo,
  ) async {
    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$owner/$repo/releases?per_page=30',
      );
      final list = _asList(response.data);

      // 遍历查找第一个 prerelease 且包含 APK 的
      for (final item in list) {
        final release = _asMap(item);
        final isPrerelease = release['prerelease'];
        if (isPrerelease == true) {
          final apkUrl = _extractApkAssetUrl(release);
          final body = release['body']?.toString();
          if (apkUrl != null) {
            return (apkUrl: apkUrl, releaseNotes: body);
          }
        }
      }

      // 如果没有 prerelease，遍历找第一个包含 APK 的 release
      for (final item in list) {
        final release = _asMap(item);
        final apkUrl = _extractApkAssetUrl(release);
        if (apkUrl != null) {
          return (
            apkUrl: apkUrl,
            releaseNotes: release['body']?.toString(),
          );
        }
      }

      return (apkUrl: null, releaseNotes: null);
    } catch (_) {
      // API 失败（限流）→ 尝试 HTML 解析
      final apkUrl = await _fetchPrereleaseApkUrlFromHtml(owner, repo);
      return (apkUrl: apkUrl, releaseNotes: null);
    }
  }

  /// 从 nightlyUrl 对应的 GitHub 仓库提取最新的 APK 直链和更新说明。
  ///
  /// nightlyUrl 可能指向与 sourceUrl 不同的仓库（如 Citron Neo 的 CI 仓库）。
  /// 解析 nightlyUrl 中的 owner/repo，查询其 releases 列表，
  /// 遍历所有 release 找到包含 APK 资产的 release。
  /// 消耗 1 次 API 配额。
  Future<({String? apkUrl, String? releaseNotes})> _fetchNightlyApkUrl(
    String nightlyUrl,
  ) async {
    final parsed = _parseRepo(nightlyUrl);
    if (parsed == null) return (apkUrl: null, releaseNotes: null);
    final (owner, repo) = parsed;

    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$owner/$repo/releases?per_page=30',
      );
      final list = _asList(response.data);
      if (list.isEmpty) return (apkUrl: null, releaseNotes: null);

      // 遍历所有 release，找到第一个包含 APK 资产的
      // （CI 仓库可能有多个 tag：nightly-windows, nightly-linux, nightly-android 等）
      for (final item in list) {
        final release = _asMap(item);
        final apkUrl = _extractApkAssetUrl(release);
        if (apkUrl != null) {
          return (
            apkUrl: apkUrl,
            releaseNotes: release['body']?.toString(),
          );
        }
      }

      // 没有找到包含 APK 的 release
      return (apkUrl: null, releaseNotes: null);
    } catch (_) {
      // API 失败 → 尝试 HTML 解析
      final apkUrl = await _fetchApkUrlFromHtml(owner, repo);
      return (apkUrl: apkUrl, releaseNotes: null);
    }
  }
  /// 从 previewUrl 对应的 GitHub 仓库提取最新预览版 APK 直链和更新说明。
  ///
  /// previewUrl 指向包含 beta/RC/preview 版本的 GitHub 仓库（可能与 sourceUrl
  /// 相同或不同）。解析 previewUrl 中的 owner/repo，查询其 releases 列表，
  /// 优先提取 prerelease 的 APK asset 和 body。消耗 1 次 API 配额。
  Future<({String? apkUrl, String? releaseNotes})> _fetchPreviewApkUrl(
    String previewUrl,
  ) async {
    final parsed = _parseRepo(previewUrl);
    if (parsed == null) return (apkUrl: null, releaseNotes: null);
    final (owner, repo) = parsed;

    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$owner/$repo/releases?per_page=30',
      );
      final list = _asList(response.data);
      if (list.isEmpty) return (apkUrl: null, releaseNotes: null);

      // 优先查找 prerelease（beta/RC/preview）且包含 APK 的
      for (final item in list) {
        final release = _asMap(item);
        final isPrerelease = release['prerelease'];
        if (isPrerelease == true) {
          final apkUrl = _extractApkAssetUrl(release);
          final body = release['body']?.toString();
          if (apkUrl != null) {
            return (apkUrl: apkUrl, releaseNotes: body);
          }
        }
      }

      // 如果没有 prerelease 标记，检查 tag 名是否含 RC/beta/preview/alpha
      for (final item in list) {
        final release = _asMap(item);
        final tag = release['tag_name']?.toString() ?? '';
        if (_isPrereleaseTag(tag)) {
          final apkUrl = _extractApkAssetUrl(release);
          final body = release['body']?.toString();
          if (apkUrl != null) {
            return (apkUrl: apkUrl, releaseNotes: body);
          }
        }
      }

      // 如果都没有标记为 prerelease，遍历找第一个包含 APK 的 release
      for (final item in list) {
        final release = _asMap(item);
        final apkUrl = _extractApkAssetUrl(release);
        if (apkUrl != null) {
          return (
            apkUrl: apkUrl,
            releaseNotes: release['body']?.toString(),
          );
        }
      }

      // 没有找到包含 APK 的 release
      return (apkUrl: null, releaseNotes: null);
    } catch (_) {
      // API 失败 → 尝试 HTML 解析
      final apkUrl = await _fetchApkUrlFromHtml(owner, repo);
      return (apkUrl: apkUrl, releaseNotes: null);
    }
  }

  /// 判断 tag 名是否包含预发布关键词（RC/beta/preview/alpha）。
  ///
  /// 部分 Forgejo/GitHub 仓库未将 RC 版本标记为 `prerelease: true`，
  /// 但 tag 名中包含 "rc"、"beta"、"preview"、"alpha" 等关键词，
  /// 通过此方法进行二次识别。
  static bool _isPrereleaseTag(String tag) {
    final lower = tag.toLowerCase();
    // RC 版本：v1.0-rc1, v1.0-rc.1, v1.0rc1 等
    if (RegExp(r'[-._]?rc[-._]?\d').hasMatch(lower)) return true;
    if (lower.contains('-rc') || lower.contains('_rc')) return true;
    // Beta 版本：v1.0-beta1, v1.0beta, v1.0-beta.1
    if (RegExp(r'[-._]?beta[-._]?\d?').hasMatch(lower)) return true;
    if (lower.contains('-beta') || lower.contains('_beta')) return true;
    // Preview 版本
    if (lower.contains('preview')) return true;
    // Alpha 版本
    if (RegExp(r'[-._]?alpha[-._]?\d?').hasMatch(lower)) return true;
    if (lower.contains('-alpha') || lower.contains('_alpha')) return true;
    return false;
  }

  /// 获取指定 tag 对应的 release 的 APK asset URL。
  ///
  /// 消耗 1 次 GitHub API 匿名配额。
  /// 仅在重定向法获取到版本号、但 asset 名含版本号无法构造稳定链接时调用。
  ///
  /// 同时尝试带 `v` 前缀和不带前缀的 tag 两种形式。
  Future<String?> _fetchAssetUrlByTag(
    String owner,
    String repo,
    String tag,
  ) async {
    // 尝试原始 tag
    var apkUrl = await _tryFetchReleaseAssets(owner, repo, tag);
    if (apkUrl != null) return apkUrl;

    // 如果原始 tag 不带 v 前缀，尝试加上
    if (!tag.startsWith('v') && !tag.startsWith('V')) {
      apkUrl = await _tryFetchReleaseAssets(owner, repo, 'v$tag');
      if (apkUrl != null) return apkUrl;
    }

    // 如果原始 tag 带 v 前缀，尝试去掉
    if (tag.startsWith('v') || tag.startsWith('V')) {
      apkUrl = await _tryFetchReleaseAssets(owner, repo, tag.substring(1));
      if (apkUrl != null) return apkUrl;
    }

    return null;
  }

  /// 请求 releases/tags/{tag} 接口并提取 APK asset URL。
  Future<String?> _tryFetchReleaseAssets(
    String owner,
    String repo,
    String tag,
  ) async {
    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$owner/$repo/releases/tags/$tag',
      );
      final release = _asMap(response.data);
      return _extractApkAssetUrl(release);
    } catch (_) {
      return null;
    }
  }

  /// HTML 解析法：从 GitHub releases 页面提取 APK 下载链接。
  ///
  /// 当 API 调用失败（限流、404 等）时作为回退方案。
  /// 直接请求 releases 页面 HTML，解析其中的 APK 下载链接。
  /// **不消耗 GitHub API 配额**。
  ///
  /// [tag] 指定具体 tag 的 releases 页面；为 null 时使用 releases/latest。
  Future<String?> _fetchApkUrlFromHtml(
    String owner,
    String repo, {
    String? tag,
  }) async {
    try {
      final url = tag != null && tag.isNotEmpty
          ? 'https://github.com/$owner/$repo/releases/tag/$tag'
          : 'https://github.com/$owner/$repo/releases/latest';

      final response = await _dio.get(
        url,
        options: Options(
          headers: {'Accept': 'text/html'},
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final html = response.data?.toString() ?? '';
      if (html.isEmpty) return null;

      return _extractApkUrlFromGitHubHtml(html);
    } catch (_) {
      return null;
    }
  }

  /// 从 GitHub releases 页面 HTML 中提取 APK 下载链接。
  ///
  /// GitHub releases 页面的 HTML 中包含形如：
  /// `/owner/repo/releases/download/v1.2.3/app.apk` 的下载链接。
  /// 使用 html 包解析 DOM，比正则更稳健。
  ///
  /// APK 选择优先级：
  /// 1. 名称含 `arm64` / `aarch64` 的 APK
  /// 2. 名称含 `standard` / `universal` / `release` 的通用 APK
  /// 3. 任意 APK（回退）
  String? _extractApkUrlFromGitHubHtml(String htmlStr) {
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

        if (href.startsWith('/')) {
          href = 'https://github.com$href';
        }

        final lower = href.toLowerCase();
        if (lower.contains('arm64') || lower.contains('aarch64')) {
          arm64Apk ??= href;
        }
        if (lower.contains('standard') ||
            lower.contains('universal') ||
            lower.contains('release')) {
          standardApk ??= href;
        }
        anyApk ??= href;
      }

      return arm64Apk ?? standardApk ?? anyApk;
    } catch (_) {
      return null;
    }
  }

  /// HTML 解析法（完整版）：从 GitHub releases 页面同时提取版本号和 APK 直链。
  ///
  /// 作为策略 4，在 API 限流时使用。不消耗 API 配额。
  Future<VersionInfo?> _fetchViaHtmlParsing(
    Emulator emulator,
    String owner,
    String repo,
  ) async {
    try {
      var response = await _dio.get(
        'https://github.com/$owner/$repo/releases/latest',
        options: Options(
          headers: {'Accept': 'text/html'},
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      // 如果 latest 返回 404（无 latest release），尝试 releases 列表页
      if (response.statusCode == 404) {
        response = await _dio.get(
          'https://github.com/$owner/$repo/releases',
          options: Options(
            headers: {'Accept': 'text/html'},
            responseType: ResponseType.plain,
          ),
        );
      }

      final html = response.data?.toString() ?? '';
      if (html.isEmpty) return null;

      // 提取 APK 下载链接
      final apkUrl = _extractApkUrlFromGitHubHtml(html);

      // 从下载链接中提取版本号
      String? version;
      if (apkUrl != null) {
        final tagMatch =
            RegExp(r'/releases/download/([^/]+)/').firstMatch(apkUrl);
        if (tagMatch != null) {
          version = _stripVPrefix(tagMatch.group(1)!);
        }
      }

      // 从 HTML meta 标签提取版本号
      if (version == null || version.isEmpty) {
        try {
          final document = html_parser.parse(html);
          final metaTag = document.querySelector(
            'meta[name="octolytics-dimension-repository_tag"]',
          );
          if (metaTag != null) {
            final content = metaTag.attributes['content'];
            if (content != null && content.isNotEmpty) {
              version = _stripVPrefix(content);
            }
          }
        } catch (_) {}
      }

      // 从页面标题提取版本号
      if (version == null || version.isEmpty) {
        final titleMatch = RegExp(
          r'Release\s+([vV]?\d+[.\d]*)',
        ).firstMatch(html);
        if (titleMatch != null) {
          version = _stripVPrefix(titleMatch.group(1)!);
        }
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

  /// 从 GitHub releases 列表页 HTML 中提取 prerelease 的 APK 下载链接。
  ///
  /// 作为 API 限流时的回退方案。从 releases 列表页 HTML 中查找
  /// prerelease 标记的 section，提取其中的 APK 下载链接。
  Future<String?> _fetchPrereleaseApkUrlFromHtml(
    String owner,
    String repo,
  ) async {
    try {
      final response = await _dio.get(
        'https://github.com/$owner/$repo/releases',
        options: Options(
          headers: {'Accept': 'text/html'},
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final html = response.data?.toString() ?? '';
      if (html.isEmpty) return null;

      final document = html_parser.parse(html);
      final releaseSections = document.querySelectorAll('.release, .Box');

      String? prereleaseApk;
      String? anyApk;

      for (final section in releaseSections) {
        final label = section.querySelector('.Label, .label');
        final isPrerelease =
            label?.text.toLowerCase().contains('pre') ?? false;

        final links = section.querySelectorAll('a[href]');
        for (final link in links) {
          var href = link.attributes['href'] ?? '';
          if (href.isEmpty) continue;
          if (!href.toLowerCase().endsWith('.apk')) continue;
          if (!href.contains('/releases/download/')) continue;

          if (href.startsWith('/')) {
            href = 'https://github.com$href';
          }

          if (isPrerelease) {
            prereleaseApk ??= href;
          }
          anyApk ??= href;
        }
      }

      // 如果 CSS 选择器未匹配到 release section，直接从整页提取
      if (prereleaseApk == null && anyApk == null) {
        return _extractApkUrlFromGitHubHtml(html);
      }

      return prereleaseApk ?? anyApk;
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
  /// **返回非 null**：链接有效，可直接使用。
  /// - 静态 URL 已是 `releases/latest/download/{asset}` 且 asset 名为静态 → 原样返回
  /// - 静态 URL 是 `releases/download/{tag}/{asset}` 且 asset 名为静态 →
  ///   转换为 `releases/latest/download/{asset}`
  ///
  /// **返回 null**：链接无效或易变，需要 API 获取真实 asset URL。
  /// - asset 名包含版本号（如 `ARMSX2-2.6.5.2.apk`）→ 版本更新后 asset 名变化，
  ///   即使 `latest/download/` 形式也会 404
  /// - 静态 URL 无法解析出 asset 名
  String? _buildDynamicDownloadUrl(
    Emulator emulator,
    String owner,
    String repo,
    String latestTag,
  ) {
    final staticUrl = emulator.downloadUrl;
    if (staticUrl.isEmpty) return null;

    // 情况 1：已经是 latest/download/{asset} 形式
    if (staticUrl.contains('/releases/latest/download/')) {
      final assetMatch =
          RegExp(r'/releases/latest/download/(.+)$').firstMatch(staticUrl);
      if (assetMatch != null) {
        final asset = assetMatch.group(1)!;
        // 检查 asset 名是否含版本号（易变）
        if (_isAssetNameVolatile(asset)) {
          return null; // asset 名含版本号 → 需 API 获取真实直链
        }
      }
      return staticUrl; // asset 名为静态，latest/download 有效
    }

    // 情况 2：releases/download/{tag}/{asset} 形式 → 转换为 latest/download
    final versionedMatch = RegExp(
      r'/releases/download/[^/]+/(.+)$',
    ).firstMatch(staticUrl);

    if (versionedMatch != null) {
      final asset = versionedMatch.group(1);
      if (asset != null && asset.isNotEmpty) {
        // 检查 asset 名是否含版本号
        if (_isAssetNameVolatile(asset)) {
          return null; // asset 名含版本号 → 需 API 获取真实直链
        }
        return 'https://github.com/$owner/$repo/releases/latest/download/$asset';
      }
    }

    // 无法从静态 URL 解析出 asset，返回 null
    return null;
  }

  /// 判断 asset 文件名是否包含版本号（即随版本更新而变化）。
  ///
  /// 包含版本号的 asset 名（如 `ARMSX2-Refresh-2.6.5.1.apk`）会随版本变化，
  /// 即使使用 `releases/latest/download/` 形式也会因 asset 名不匹配而 404。
  ///
  /// 匹配模式：
  /// - `x.y.z`（如 `2.6.5.1`、`1.2.3`）
  /// - `x.y`（如 `2.6`、`0.5`）
  /// - `x.y.z.build`（如 `4.0.Build.7533`）
  bool _isAssetNameVolatile(String assetName) {
    // 匹配 x.y.z 或更多点分段版本号
    if (RegExp(r'\d+\.\d+\.\d+').hasMatch(assetName)) return true;
    // 匹配 x.y 格式版本号
    if (RegExp(r'\d+\.\d+').hasMatch(assetName)) return true;
    return false;
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
