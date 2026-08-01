import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/models/emulator.dart';
import '../../data/models/version_info.dart';
import 'version_adapter.dart';
import 'version_comparator.dart';

/// 基于 GitHub Releases 的版本适配器。
///
/// 适用于 [Emulator.sourceType] 为 `github` 的模拟器。
///
/// **核心策略**（按优先级）：
///
/// 1. **重定向法（主）**：请求 `https://github.com/owner/repo/releases/latest`，
///    GitHub 会 302 重定向到 `https://github.com/owner/repo/releases/tag/v1.2.3`，
///    从重定向 Location 头直接提取版本号（不消耗配额）。
///    随后调用 API `releases/tags/{tag}` 获取 release body（更新说明）、
///    asset URL 和 published_at 日期（消耗 1 次配额）。
///    若 API 因限流失败，回退到动态下载链接构造，releaseNotes 为 null。
///
/// 2. **API releases 列表**：当重定向目标是 `/releases`（无 latest 标记）时，
///    请求 `releases?per_page=1` 取最新一条 release。消耗 1 次 API 配额。
///
/// 3. **API tags**：仓库完全没有 release 时，从 `tags?per_page=1` 取最新 tag。
///    消耗 1 次 API 配额。
///
/// 策略 1-3 均消耗 GitHub API 匿名配额（60 次/小时），策略 1 的重定向本身不限流。
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

    // 策略 0：HTML 解析法（不消耗 API 配额）
    result = await _fetchFromHtml(emulator, owner, repo);

    // 策略 1：重定向法（不消耗 API 配额）
    if (result == null) {
      result = await _fetchViaRedirect(emulator, owner, repo);
    }

    // 策略 2：API releases 列表（消耗 1 次配额）
    if (result == null) {
      result = await _fetchFromApiReleasesList(emulator, owner, repo);
    }

    // 策略 3：API tags（消耗 1 次配额）
    if (result == null) {
      result = await _fetchFromTags(emulator, owner, repo);
    }

    // 如果成功获取到版本信息，且模拟器有 devUrl，尝试获取 prerelease 信息
    // 并检查预发布版是否比稳定版更新
    if (result != null && emulator.devUrl.isNotEmpty) {
      // 优先用 HTML 解析（不消耗 API 配额），失败时回退到 API
      var devInfo = await _fetchPrereleaseInfoFromHtml(owner, repo);
      if (devInfo == null) {
        devInfo = await _fetchPrereleaseInfo(owner, repo);
      }
      if (devInfo != null) {
        result = result.copyWith(
          devDownloadUrl: devInfo.apkUrl,
          devReleaseNotes: devInfo.body,
        );

        // 如果预发布版版本号比稳定版更新，将预发布版作为主版本显示
        // 例如：稳定版 2125.1.3，预发布版 2126.0-rc5 → 显示 2126.0-rc5
        if (devInfo.version != null && devInfo.version!.isNotEmpty) {
          final stableVersion = result.version;
          final devVersion = devInfo.version!;
          if (VersionComparator.isNewer(stableVersion, devVersion)) {
            result = result.copyWith(
              version: devVersion,
              releaseDate: devInfo.publishedAt ?? result.releaseDate,
              releaseNotes: devInfo.body ?? result.releaseNotes,
              downloadUrl: devInfo.apkUrl ?? result.downloadUrl,
            );
          }
        }
      }
    }

    return result;
  }

  /// 通过 HTML 解析获取最新 prerelease 信息（不消耗 API 配额）。
  ///
  /// 请求 releases 页面 HTML，解析 release 列表，查找第一个标记为
  /// "Pre-release" 的 release。获取其 tag（版本号）后，再通过
  /// expanded_assets 端点获取 APK 直链。
  ///
  /// 相比 _fetchPrereleaseInfo（使用 API），此方法不消耗 API 配额，
  /// 是首选方法。仅在 HTML 解析失败时才回退到 API。
  Future<({String? version, String? apkUrl, String? body, DateTime? publishedAt})?> _fetchPrereleaseInfoFromHtml(
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

      // 从 HTML 中提取 release 列表
      // 每个release条目包含 tag链接 和 标签（Pre-release 或 Latest）
      final releasePattern = RegExp(
        r'href="[^"]*releases/tag/([^"]+)"[^>]*>[\s\S]{0,500}?(Pre-release|latest)',
        caseSensitive: false,
      );
      final matches = releasePattern.allMatches(html);

      // 查找第一个 Pre-release
      for (final match in matches) {
        final tag = match.group(1)!;
        final label = match.group(2)!;

        if (label.toLowerCase().contains('pre')) {
          final version = _stripVPrefix(tag);

          // 通过 expanded_assets 获取 APK 直链
          final apkUrl = await _fetchApkUrlFromExpandedAssets(owner, repo, tag);

          // 从 tag 页面 HTML 获取更新说明和发布日期
          String? body;
          DateTime? publishedAt;
          try {
            final tagResponse = await _dio.get(
              'https://github.com/$owner/$repo/releases/tag/$tag',
              options: Options(
                responseType: ResponseType.plain,
                followRedirects: true,
                validateStatus: (status) => status != null && status < 400,
              ),
            );
            final tagHtml = tagResponse.data.toString();
            body = _extractReleaseNotesFromHtml(tagHtml);
            publishedAt = _extractReleaseDateFromHtml(tagHtml);
          } catch (_) {}

          return (
            version: version,
            apkUrl: apkUrl,
            body: body,
            publishedAt: publishedAt,
          );
        }
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  /// 重定向法：请求 releases/latest 页面，从 302 重定向 URL 提取版本号。
  ///
  /// 返回 `null` 的情况：
  /// - 重定向到 `/releases`（有 releases 但无 latest 标记）→ 需要策略 2
  /// - 返回 404（完全无 releases）→ 需要策略 3
  /// - 网络错误
  ///
  /// 成功后，始终调用 API `releases/tags/{tag}` 获取 release body（更新说明）
  /// 和 published_at 发布日期，消耗 1 次 API 配额。
  /// 若 API 调用因限流失败，则回退到动态下载链接构造，releaseNotes 为 null。
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

      // 始终通过 API 获取 release body（更新说明）+ asset URL + 发布日期
      final releaseInfo = await _fetchReleaseInfoByTag(owner, repo, tag);

      // 如果 API 成功，使用其 asset URL 和 release body
      if (releaseInfo != null) {
        return VersionInfo(
          emulatorId: emulator.id,
          version: version,
          releaseDate: releaseInfo.publishedAt ?? DateTime.now(),
          releaseNotes: releaseInfo.body,
          isNew: false,
          downloadUrl: releaseInfo.apkUrl,
        );
      }

      // API 失败（限流或网络错误）→ 通过 expanded_assets 获取 APK 链接
      final htmlNotes = await _fetchReleaseNotesFromHtml(owner, repo, tag);
      var dynamicDownloadUrl = await _fetchApkUrlFromExpandedAssets(
        owner, repo, tag,
      );
      // expanded_assets 也失败 → 尝试从静态 URL 动态构造
      if (dynamicDownloadUrl == null) {
        dynamicDownloadUrl = _buildDynamicDownloadUrl(
          emulator, owner, repo, tag,
        );
      }

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: DateTime.now(),
        releaseNotes: htmlNotes,
        isNew: false,
        downloadUrl: dynamicDownloadUrl,
      );
    } catch (_) {
      return null;
    }
  }

  /// HTML 解析法：从 GitHub releases 页面提取全部版本信息（不消耗 API 配额）。
  ///
  /// 请求 `releases/latest` 页面（GitHub 会 302 重定向到 tag 页面），
  /// 从最终 URL 提取版本号，从 HTML 提取更新说明和发布日期。
  /// APK 下载链接通过 `releases/expanded_assets/{tag}` 端点单独获取
  /// （GitHub 已改用 JavaScript 动态渲染 asset 列表，静态 HTML 不含下载链接）。
  ///
  /// 当 releases/latest 重定向到 /releases（无 latest 标记）时，
  /// 从 HTML 内容中提取第一个 release 的 tag。
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
      String? tag;
      final urlTagMatch =
          RegExp(r'/releases/tag/(.+?)(?:\?|#|$)').firstMatch(finalUrl);
      if (urlTagMatch != null) {
        tag = urlTagMatch.group(1);
      }

      // 如果 URL 中没有 tag（重定向到 /releases），从 HTML 内容提取第一个 tag
      final tagFromList = tag == null || tag.isEmpty;
      if (tagFromList) {
        tag = _extractFirstTagFromHtml(html);
        if (tag == null || tag.isEmpty) return null;
      }

      final version = _stripVPrefix(tag);
      if (version.isEmpty) return null;

      // 2. 从 HTML 提取更新说明
      //    如果 tag 是从 releases 列表页提取的（非 tag 页面），
      //    列表页的 markdown-body 可能不包含完整更新说明，
      //    额外请求 tag 页面获取完整内容。
      String? releaseNotes = _extractReleaseNotesFromHtml(html);
      if (tagFromList) {
        final tagPageNotes = await _fetchReleaseNotesFromHtml(
          owner, repo, tag,
        );
        if (tagPageNotes != null && tagPageNotes.isNotEmpty) {
          releaseNotes = tagPageNotes;
        }
      }

      // 3. 通过 expanded_assets 端点提取 APK 下载链接（不消耗 API 配额）
      //    GitHub 已改用 JavaScript 动态渲染 asset 列表，静态 HTML 不含下载链接。
      //    expanded_assets/{tag} 返回包含 asset 链接的 HTML 片段。
      var apkUrl = await _fetchApkUrlFromExpandedAssets(owner, repo, tag);

      // 4. 如果 expanded_assets 失败，尝试从静态 URL 动态构造
      if (apkUrl == null) {
        apkUrl = _buildDynamicDownloadUrl(emulator, owner, repo, tag);
      }

      // 5. 从 HTML 提取发布日期
      //    如果 tag 是从列表页提取的，也尝试从 tag 页面获取日期
      DateTime? releaseDate = _extractReleaseDateFromHtml(html);
      if (tagFromList) {
        try {
          final tagResponse = await _dio.get(
            'https://github.com/$owner/$repo/releases/tag/$tag',
            options: Options(
              responseType: ResponseType.plain,
              followRedirects: true,
              validateStatus: (status) => status != null && status < 400,
            ),
          );
          final tagHtml = tagResponse.data.toString();
          final tagDate = _extractReleaseDateFromHtml(tagHtml);
          if (tagDate != null) releaseDate = tagDate;
        } catch (_) {}
      }

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

  /// 通过 GitHub 的 `expanded_assets/{tag}` 端点提取 APK 下载链接。
  ///
  /// GitHub releases 页面的 asset 列表通过 JavaScript 动态加载，
  /// 静态 HTML 中不包含下载链接。该端点返回包含 asset 链接的 HTML 片段，
  /// 无需消耗 GitHub API 配额。
  ///
  /// 返回 arm64/aarch64 架构的 APK 链接优先，否则返回第一个 APK 链接。
  Future<String?> _fetchApkUrlFromExpandedAssets(
    String owner,
    String repo,
    String tag,
  ) async {
    try {
      final response = await _dio.get(
        'https://github.com/$owner/$repo/releases/expanded_assets/$tag',
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: true,
          validateStatus: (status) => status != null && status < 400,
        ),
      );

      final html = response.data.toString();
      return _extractApkUrlFromHtml(html);
    } catch (_) {
      return null;
    }
  }

  /// 从指定 tag 的 release 页面 HTML 中提取更新说明（不消耗 API 配额）。
  Future<String?> _fetchReleaseNotesFromHtml(
    String owner,
    String repo,
    String tag,
  ) async {
    try {
      final response = await _dio.get(
        'https://github.com/$owner/$repo/releases/tag/$tag',
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: true,
          validateStatus: (status) => status != null && status < 400,
        ),
      );
      final html = response.data.toString();
      return _extractReleaseNotesFromHtml(html);
    } catch (_) {
      return null;
    }
  }

  /// 从 GitHub releases 页面 HTML 提取 release notes。
  ///
  /// GitHub release 页面的更新说明位于 `<div class="markdown-body">` 元素中。
  String? _extractReleaseNotesFromHtml(String html) {
    final patterns = <RegExp>[
      // 主匹配：markdown-body div（非贪婪匹配到闭合标签）
      RegExp(
        r'<div[^>]*class="[^"]*markdown-body[^"]*"[^>]*>([\s\S]*?)</div>',
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      if (match != null) {
        var content = match.group(1)!;
        // Strip HTML tags
        content = content.replaceAll(RegExp(r'<[^>]+>'), '');
        // Decode HTML entities
        content = _decodeHtmlEntities(content);
        // Clean up whitespace
        content = content
            .replaceAll(RegExp(r'\n{3,}'), '\n\n')
            .trim();
        if (content.isNotEmpty) {
          return content;
        }
      }
    }
    return null;
  }

  /// 从 GitHub releases 页面 HTML 提取 APK 下载链接。
  ///
  /// 优先返回 arm64/aarch64 架构的 APK。
  String? _extractApkUrlFromHtml(String html) {
    String? arm64Apk;
    String? anyApk;

    final apkPattern = RegExp(
      r'href="([^"]*\.apk)"',
      caseSensitive: false,
    );

    for (final match in apkPattern.allMatches(html)) {
      var url = match.group(1)!;
      if (url.startsWith('/')) {
        url = 'https://github.com$url';
      }
      final name = url.toLowerCase();
      if (name.contains('arm64') ||
          name.contains('aarch64') ||
          name.contains('arm64-v8a')) {
        arm64Apk ??= url;
      }
      anyApk ??= url;
    }

    return arm64Apk ?? anyApk;
  }

  /// 从 GitHub releases 页面 HTML 提取发布日期。
  DateTime? _extractReleaseDateFromHtml(String html) {
    final patterns = <RegExp>[
      RegExp(r'<relative-time[^>]*datetime="([^"]+)"', caseSensitive: false),
      RegExp(r'<time[^>]*datetime="([^"]+)"', caseSensitive: false),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      if (match != null) {
        final date = _parseDate(match.group(1));
        if (date != null) return date;
      }
    }
    return null;
  }

  /// 当 releases/latest 重定向到 /releases（无 latest 标记）时，
  /// 从 HTML 内容中提取第一个 release 的 tag。
  ///
  /// GitHub releases 页面 HTML 包含类似以下的链接：
  /// `<a href="/owner/repo/releases/tag/TAG_NAME">`
  ///
  /// 优先选择非 Pre-release 的稳定版；若全部为 Pre-release，则返回第一个。
  String? _extractFirstTagFromHtml(String html) {
    final tagPattern = RegExp(
      r'href="[^"]*releases/tag/([^"]+)"',
    );

    String? firstStableTag;
    String? firstAnyTag;

    for (final match in tagPattern.allMatches(html)) {
      final tag = match.group(1)!;
      if (tag.isEmpty) continue;

      firstAnyTag ??= tag;

      // 检查该 tag 附近是否有 "Pre-release" 标记
      // 在 tag 链接之后 500 字符内查找 "Pre-release" 标签
      final checkEnd =
          match.end + 500 < html.length ? match.end + 500 : html.length;
      final afterTag = html.substring(match.end, checkEnd);
      if (!afterTag.toLowerCase().contains('pre-release') &&
          !afterTag.toLowerCase().contains('pre release')) {
        firstStableTag ??= tag;
      }
    }

    return firstStableTag ?? firstAnyTag;
  }

  /// 解码 HTML 实体。
  String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#x2F;', '/')
        .replaceAll('&#x27;', "'");
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

  /// 获取最新的 prerelease（开发版/预览版）信息。
  ///
  /// 查询 releases 列表（per_page=10），从中筛选第一个 `prerelease=true`
  /// 的 release，提取其版本号、APK asset URL、body（更新说明）和发布日期。
  /// 消耗 1 次 API 配额。
  ///
  /// 仅对配置了 devUrl 的模拟器调用，避免不必要的 API 消耗。
  /// 返回 null 表示无 prerelease 或 API 调用失败。
  Future<({String? version, String? apkUrl, String? body, DateTime? publishedAt})?> _fetchPrereleaseInfo(
    String owner,
    String repo,
  ) async {
    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$owner/$repo/releases?per_page=10',
      );
      final list = _asList(response.data);

      // 遍历查找第一个 prerelease
      for (final item in list) {
        final release = _asMap(item);
        final isPrerelease = release['prerelease'];
        if (isPrerelease == true) {
          final tag = release['tag_name']?.toString();
          if (tag == null || tag.isEmpty) continue;

          final version = _stripVPrefix(tag);
          final apkUrl = _extractApkAssetUrl(release);
          final publishedAt = _parseDate(release['published_at']?.toString());

          return (
            version: version,
            apkUrl: apkUrl,
            body: release['body']?.toString(),
            publishedAt: publishedAt,
          );
        }
      }

      // 仓库没有 prerelease：返回 null。
      // 注意不能用 releases 列表中第二新的 release 冒充开发版，
      // 那通常只是更旧的稳定版，会误导用户下载旧包。
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 通过 API 获取指定 tag 对应 release 的完整信息（APK 直链 + body + 发布日期）。
  ///
  /// 消耗 1 次 GitHub API 匿名配额。
  /// 在重定向法获取到版本号后调用，用于获取更新说明和真实 asset 直链。
  ///
  /// 同时尝试带 `v` 前缀和不带前缀的 tag 两种形式。
  Future<({String? apkUrl, String? body, DateTime? publishedAt})?> _fetchReleaseInfoByTag(
    String owner,
    String repo,
    String tag,
  ) async {
    // 尝试原始 tag
    var result = await _tryFetchReleaseInfo(owner, repo, tag);
    if (result != null) return result;

    // 如果原始 tag 不带 v 前缀，尝试加上
    if (!tag.startsWith('v') && !tag.startsWith('V')) {
      result = await _tryFetchReleaseInfo(owner, repo, 'v$tag');
      if (result != null) return result;
    }

    // 如果原始 tag 带 v 前缀，尝试去掉
    if (tag.startsWith('v') || tag.startsWith('V')) {
      result = await _tryFetchReleaseInfo(owner, repo, tag.substring(1));
      if (result != null) return result;
    }

    return null;
  }

  /// 请求 releases/tags/{tag} 接口并提取完整 release 信息。
  Future<({String? apkUrl, String? body, DateTime? publishedAt})?> _tryFetchReleaseInfo(
    String owner,
    String repo,
    String tag,
  ) async {
    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$owner/$repo/releases/tags/$tag',
      );
      final release = _asMap(response.data);
      return (
        apkUrl: _extractApkAssetUrl(release),
        body: release['body']?.toString(),
        publishedAt: _parseDate(release['published_at']?.toString()),
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
