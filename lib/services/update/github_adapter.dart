import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

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
/// 最后读取官方 Atom Feed，并在稳定版、预发布版和 nightly 中按精确发布
/// 时间选择最新一条。GitHub Releases 页面的显示顺序不保证按发布时间排序，
/// 因此不能把页面第一条或 `/releases/latest` 当作“时间最新”。
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
                  // GitHub 对缺少明确客户端标识的移动端请求偶尔返回限制页，
                  // 导致只能拿到 latest 重定向中的版本号，日期和说明为空。
                  'User-Agent':
                      'EmuHub/1.0 (+https://github.com/kongmao4567890-glitch/emuhub)',
                },
              ),
            );

  final Dio _dio;
  final Map<String, ({DateTime fetchedAt, Future<String?> response})>
      _atomFeedCache = {};

  @override
  String get adapterName => 'github';

  /// 为 GitHub HTML 页面请求创建 [Options]。
  ///
  /// Dio 实例默认带 `Accept: application/vnd.github+json`（API header），
  /// 但 GitHub 的 `/releases` 页面会对此返回 **HTTP 406 Not Acceptable**。
  /// 所有 HTML 页面请求必须覆盖此 header 为 `text/html`。
  ///
  /// 受影响的 URL 模式：
  /// - `github.com/owner/repo/releases` → 406（不接受 API Accept）
  /// - `github.com/owner/repo/releases/latest` → 200（不受影响，但保持一致）
  /// - `github.com/owner/repo/releases/tag/{tag}` → 200（不受影响）
  /// - `github.com/owner/repo/releases/expanded_assets/{tag}` → 200（不受影响）
  Options _htmlOptions({bool followRedirects = true}) {
    return Options(
      responseType: ResponseType.plain,
      followRedirects: followRedirects,
      validateStatus: (status) => status != null && status < 400,
      // 慢速 VPN 网络下 GitHub releases 页面可达 700KB，
      // 默认 15s 超时不够，增加到 30s。
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Accept': 'text/html, application/xhtml+xml, */*',
        'User-Agent':
            'EmuHub/1.0 (+https://github.com/kongmao4567890-glitch/emuhub)',
      },
    );
  }

  Options _atomOptions() {
    return Options(
      responseType: ResponseType.plain,
      followRedirects: true,
      validateStatus: (status) => status != null && status < 400,
      receiveTimeout: const Duration(seconds: 45),
      headers: {
        'Accept': 'application/atom+xml, application/xml, text/xml, */*',
        'User-Agent':
            'EmuHub/1.0 (+https://github.com/kongmao4567890-glitch/emuhub)',
      },
    );
  }

  @override
  Future<VersionInfo?> fetchLatestVersion(
    Emulator emulator, {
    bool includeDetails = false,
  }) async {
    final parsed = _parseRepo(emulator.sourceUrl);
    if (parsed == null) return null;
    final (owner, repo) = parsed;

    VersionInfo? result;

    // 策略 1：轻量重定向法（不消耗 API 配额，也不下载完整 release 页面）
    result = await _fetchViaRedirect(emulator, owner, repo);

    // 策略 2：HTML 解析法（仅作为无 latest 重定向时的回退）
    if (result == null) {
      result = await _fetchFromHtml(emulator, owner, repo);
    }

    // 策略 3：API releases 列表（消耗 1 次配额）
    if (result == null) {
      result = await _fetchFromApiReleasesList(
        emulator,
        owner,
        repo,
        includeCommitMessage: includeDetails,
      );
    }

    // 策略 4：API tags（消耗 1 次配额）
    if (result == null) {
      result = await _fetchFromTags(
        emulator,
        owner,
        repo,
        includeCommitDetails: includeDetails,
      );
    }

    final tracksGitHubPrerelease = _tracksGitHubPrerelease(
      emulator,
      owner: owner,
      repo: repo,
    );

    // `/releases/latest` 只代表 GitHub 标记的 Latest 稳定版，Releases 页面
    // 的第一条也不保证是 published_at 最大的一条。统一遍历官方 Atom Feed
    // 中的发布，按精确时间选择稳定版/prerelease/nightly 中最新的版本。
    var latestPublished = await _fetchLatestPublishedReleaseFromAtom(
      emulator,
      owner,
      repo,
    );

    // 少数条目把 nightly/开发版放在另一个 GitHub 仓库（例如 Citron CI）。
    // 这些仓库也属于同一条目的可用发布渠道，必须跨仓库比较发布时间。
    for (final channel in _configuredGitHubChannelRepos(
      emulator,
      primaryOwner: owner,
      primaryRepo: repo,
    )) {
      final candidate = await _fetchLatestPublishedReleaseFromAtom(
        emulator,
        channel.owner,
        channel.repo,
      );
      final candidateDate = candidate?.releaseDate;
      final selectedDate = latestPublished?.releaseDate;
      if (candidate != null &&
          (latestPublished == null ||
              (candidateDate != null &&
                  (selectedDate == null ||
                      candidateDate.isAfter(selectedDate))))) {
        latestPublished = candidate;
      }
    }

    if (latestPublished != null) {
      final previous = result;
      final previousDownloadUrl = previous != null &&
              _sameVersion(previous.version, latestPublished.version)
          ? previous.downloadUrl
          : null;
      result = latestPublished.copyWith(
        downloadUrl: latestPublished.downloadUrl ?? previousDownloadUrl,
      );
    }

    // 详情页需要完整更新说明；批量/后台检查只取轻量版本信息。
    if (result != null && includeDetails) {
      final detailed = await _fetchFromHtml(emulator, owner, repo);
      if (detailed != null &&
          !VersionComparator.isNewer(result.version, detailed.version) &&
          !VersionComparator.isNewer(detailed.version, result.version)) {
        result = result.copyWith(
          releaseDate: detailed.releaseDate ?? result.releaseDate,
          releaseNotes: detailed.releaseNotes ?? result.releaseNotes,
          downloadUrl: detailed.downloadUrl ?? result.downloadUrl,
        );
      }

      // GitHub 的 HTML 结构偶尔变化或页面尚未完整返回时，日期/说明可能解析
      // 不到。详情页再用 latest release API 补齐一次，避免必须手动刷新。
      if (result.releaseDate == null || result.releaseNotes == null) {
        final apiDetailed =
            await _fetchFromApiLatestRelease(emulator, owner, repo);
        if (apiDetailed != null &&
            !VersionComparator.isNewer(result.version, apiDetailed.version) &&
            !VersionComparator.isNewer(apiDetailed.version, result.version)) {
          result = result.copyWith(
            releaseDate: apiDetailed.releaseDate ?? result.releaseDate,
            releaseNotes: apiDetailed.releaseNotes ?? result.releaseNotes,
            downloadUrl: apiDetailed.downloadUrl ?? result.downloadUrl,
          );
        }
      }

      // 全部 release 都是 prerelease 时，GitHub 的 /releases/latest API
      // 会返回 404；HTML 页面虽可解析出版本和日期，却经常拿不到正文。
      // 再读取 release 列表中当前第一条，并在正文为空时使用对应提交信息。
      if (result.releaseNotes == null) {
        final apiFirst = await _fetchFromApiReleasesList(
          emulator,
          owner,
          repo,
          includeCommitMessage: true,
        );
        if (apiFirst != null &&
            _sameVersion(result.version, apiFirst.version)) {
          result = result.copyWith(
            releaseDate: apiFirst.releaseDate ?? result.releaseDate,
            releaseNotes: apiFirst.releaseNotes,
            downloadUrl: apiFirst.downloadUrl ?? result.downloadUrl,
          );
        }
      }

      // GitHub API 匿名额度耗尽、HTML 结构临时变化或移动网络返回精简页时，
      // latest 重定向通常仍能提供版本号，但日期和正文会缺失。官方 Atom
      // Release Feed 不消耗 API 配额，并包含发布时间及完整 release body，
      // 因此仅在详情仍不完整时作为最后回退。RPCS3 这类正文很长、又采用
      // 滚动发布的项目也能在一次检查中补齐信息，无需再次点击刷新。
      if (result.releaseDate == null || result.releaseNotes == null) {
        final atomDetailed = await _fetchFromAtom(
          emulator,
          owner,
          repo,
          preferredVersion: result.version,
        );
        if (atomDetailed != null &&
            _sameVersion(result.version, atomDetailed.version)) {
          result = result.copyWith(
            releaseDate: atomDetailed.releaseDate ?? result.releaseDate,
            releaseNotes: atomDetailed.releaseNotes ?? result.releaseNotes,
            downloadUrl: atomDetailed.downloadUrl ?? result.downloadUrl,
          );
        }
      }
    }

    // 如果成功获取到版本信息，继续抓取 prerelease 信息作为独立开发渠道。
    // 主卡片已经由所有发布的最大时间戳确定；这里仅补充独立开发渠道按钮。
    //
    // 仅对明确配置了开发版或 nightly 渠道的条目检查预发布版，避免批量
    // 检查时为所有 GitHub 仓库下载体积较大的 releases 列表页。
    // nightlyUrl 与 devUrl 都代表用户希望跟踪的非稳定发布渠道。
    if (result != null && tracksGitHubPrerelease) {
      // 优先复用已缓存的 Atom Feed，避免再下载体积较大的
      // Releases HTML。Feed 无法识别某些无特征标签时，再回退 HTML/API。
      var devInfo = await _fetchPrereleaseInfoFromAtom(owner, repo);
      devInfo ??= await _fetchPrereleaseInfoFromHtml(owner, repo);
      if (devInfo == null) {
        devInfo = await _fetchPrereleaseInfo(owner, repo);
      }
      if (devInfo != null) {
        // 轻量路径只从 latest 重定向中得到稳定版 tag，没有发布日期；为
        // 正确比较稳定版与预发布版，需要补齐稳定版详情。仅在配置了额外
        // 渠道的 GitHub 条目执行，不会拖慢普通模拟器的批量更新。
        if (result.releaseDate == null) {
          final stableDetails = await _fetchFromHtml(emulator, owner, repo);
          if (stableDetails != null &&
              _sameVersion(result.version, stableDetails.version)) {
            result = result.copyWith(
              releaseDate: stableDetails.releaseDate ?? result.releaseDate,
              releaseNotes: stableDetails.releaseNotes ?? result.releaseNotes,
              downloadUrl: stableDetails.downloadUrl ?? result.downloadUrl,
            );
          }
        }

        result = result.copyWith(
          devDownloadUrl: devInfo.apkUrl,
          devReleaseNotes: devInfo.body,
        );
      }
    }

    return result;
  }

  static bool _sameVersion(String first, String second) =>
      !VersionComparator.isNewer(first, second) &&
      !VersionComparator.isNewer(second, first);

  /// 只有开发/每夜版链接确实指向当前 GitHub 仓库时，才扫描 prerelease。
  ///
  /// RPCS3 等项目把滚动构建放在独立官网；此前只要 devUrl 非空就会额外
  /// 扫描 GitHub releases，不仅找不到开发版，还会拖慢批量更新并增加限流
  /// 风险。外部渠道由静态链接直接展示，不进行无意义的 GitHub 请求。
  bool _tracksGitHubPrerelease(
    Emulator emulator, {
    required String owner,
    required String repo,
  }) {
    for (final url in <String>[emulator.devUrl, emulator.nightlyUrl]) {
      final uri = Uri.tryParse(url);
      if (uri == null || uri.host != 'github.com') continue;
      final segments = uri.pathSegments
          .where((part) => part.isNotEmpty)
          .toList();
      if (segments.length >= 2 &&
          segments[0].toLowerCase() == owner.toLowerCase() &&
          segments[1].toLowerCase() == repo.toLowerCase()) {
        return true;
      }
    }
    return false;
  }

  List<({String owner, String repo})> _configuredGitHubChannelRepos(
    Emulator emulator, {
    required String primaryOwner,
    required String primaryRepo,
  }) {
    final channels = <String, ({String owner, String repo})>{};
    for (final url in <String>[emulator.devUrl, emulator.nightlyUrl]) {
      final parsed = _parseRepo(url);
      if (parsed == null) continue;
      final (owner, repo) = parsed;
      if (owner.toLowerCase() == primaryOwner.toLowerCase() &&
          repo.toLowerCase() == primaryRepo.toLowerCase()) {
        continue;
      }
      channels['${owner.toLowerCase()}/${repo.toLowerCase()}'] = (
        owner: owner,
        repo: repo,
      );
    }
    return channels.values.toList(growable: false);
  }

  /// 通过 HTML 解析获取最新 prerelease 信息（不消耗 API 配额）。
  ///
  /// 请求 releases 页面 HTML，解析 release 列表，查找预发布版。
  ///
  /// **检测策略**（双重检测，提高可靠性）：
  /// 1. **标签检测**：查找 HTML 中标记为 "Pre-release" 的 release
  /// 2. **Tag 名检测**：查找 tag 名包含预发布标识（rc/beta/alpha/pre）的 release
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
        options: _htmlOptions(),
      );

      final html = response.data.toString();

      // 策略 1：查找 HTML 中标记为 "Pre-release" 的 release
      // GitHub releases 页面中，预发布版会带有 Label--prerelease 类
      // 或文本 "Pre-release"。查找 tag 链接后 800 字符内的 "Pre-release" 标签。
      final prereleaseLabelPattern = RegExp(
        r'href="[^"]*releases/tag/([^"]+)"[\s\S]{0,800}?(?:Label--prerelease|Pre-release)',
        caseSensitive: false,
      );
      final labelMatches = prereleaseLabelPattern.allMatches(html);

      for (final match in labelMatches) {
        final tag = match.group(1)!;
        if (tag.isEmpty) continue;
        return _buildPrereleaseInfo(owner, repo, tag);
      }

      // 策略 2：Tag 名包含预发布标识（rc/beta/alpha/pre/dev/nightly）
      // 有些仓库的 HTML 结构可能不同，标签检测可能失效，
      // 但 tag 名本身通常包含预发布标识。
      final allTagsPattern = RegExp(
        r'href="[^"]*releases/tag/([^"]+)"',
      );
      final allTagMatches = allTagsPattern.allMatches(html);

      for (final match in allTagMatches) {
        final tag = match.group(1)!;
        if (tag.isEmpty) continue;
        final tagLower = tag.toLowerCase();
        // 检查 tag 名是否包含预发布标识
        if (_isPrereleaseTag(tagLower)) {
          return _buildPrereleaseInfo(owner, repo, tag);
        }
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  /// 判断 tag 名是否为预发布版。
  ///
  /// 常见预发布标识：rc、beta、alpha、pre、dev、nightly、snapshot、preview。
  /// 使用正则匹配分隔符后的标识，避免误匹配（如 "arcade" 包含 "rc"）。
  static bool _isPrereleaseTag(String tagLower) {
    // 匹配 dash/dot/underscore 后跟预发布标识
    final prePattern = RegExp(r'[-_.](rc|beta|alpha|pre|dev)');
    // 也匹配数字后直接跟 rc（如 1.0.0rc5）
    final rcAfterDigit = RegExp(r'\drc');
    // nightly/snapshot/preview 可以出现在任意位置
    return prePattern.hasMatch(tagLower) ||
        rcAfterDigit.hasMatch(tagLower) ||
        tagLower.contains('nightly') ||
        tagLower.contains('snapshot') ||
        tagLower.contains('preview');
  }

  /// 构建预发布版信息：获取 APK 直链、更新说明和发布日期。
  Future<({String? version, String? apkUrl, String? body, DateTime? publishedAt})> _buildPrereleaseInfo(
    String owner,
    String repo,
    String tag,
  ) async {
    final version = _stripVPrefix(tag);

    // 通过 expanded_assets 获取 APK 直链
    final apkUrl = await _fetchApkUrlFromExpandedAssets(owner, repo, tag);

    // 从 tag 页面 HTML 获取更新说明和发布日期
    String? body;
    DateTime? publishedAt;
    try {
      final tagResponse = await _dio.get(
        'https://github.com/$owner/$repo/releases/tag/$tag',
        options: _htmlOptions(),
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

  /// 重定向法：请求 releases/latest 页面，从 302 重定向 URL 提取版本号。
  ///
  /// 返回 `null` 的情况：
  /// - 重定向到 `/releases`（有 releases 但无 latest 标记）→ 需要策略 2
  /// - 返回 404（完全无 releases）→ 需要策略 3
  /// - 网络错误
  ///
  /// 成功后仅请求轻量的 `expanded_assets` HTML 片段解析 APK，不请求完整
  /// release 页面或 API。更新说明会在必要的回退路径中补充。
  Future<VersionInfo?> _fetchViaRedirect(
    Emulator emulator,
    String owner,
    String repo,
  ) async {
    try {
      final response = await _dio.head(
        'https://github.com/$owner/$repo/releases/latest',
        options: _htmlOptions(followRedirects: false),
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
        // 重定向只提供 tag，不包含发布日期。保持为空，详情检查再补全。
        releaseDate: null,
        releaseNotes: null,
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
        options: _htmlOptions(),
      );

      final html = response.data.toString();
      final finalUrl = response.realUri.toString();

      // 1. 从最终 URL 提取版本号：.../releases/tag/v1.2.3
      final urlTagMatch =
          RegExp(r'/releases/tag/(.+?)(?:\?|#|$)').firstMatch(finalUrl);
      String? tag = urlTagMatch?.group(1);

      // 如果 URL 中没有 tag（重定向到 /releases），从 HTML 内容提取第一个 tag
      final tagFromList = tag == null || tag.isEmpty;
      if (tagFromList) {
        tag = _extractFirstTagFromHtml(html);
      }
      if (tag == null || tag.isEmpty) return null;

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
            options: _htmlOptions(),
          );
          final tagHtml = tagResponse.data.toString();
          final tagDate = _extractReleaseDateFromHtml(tagHtml);
          if (tagDate != null) releaseDate = tagDate;
        } catch (_) {}
      }

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: releaseDate,
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
        options: _htmlOptions(),
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
        options: _htmlOptions(),
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
    try {
      final document = html_parser.parse(html);
      final releaseBody = document.querySelector('.markdown-body');
      final content = releaseBody?.text
          .replaceAll(RegExp(r'[ \t]+'), ' ')
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .trim();
      return content == null || content.isEmpty ? null : content;
    } catch (_) {
      return null;
    }
  }

  /// 从 GitHub 官方 releases.atom 补全指定版本的日期与更新说明。
  ///
  /// Feed 与 Releases 页面使用同一份发布正文，但不受 API 每小时 60 次的
  /// 匿名限额影响。只在常规 HTML/API 详情抓取失败后调用，避免增加正常
  /// 批量检查的流量。
  Future<VersionInfo?> _fetchFromAtom(
    Emulator emulator,
    String owner,
    String repo, {
    required String preferredVersion,
  }) async {
    try {
      final feed = await _fetchAtomFeed(owner, repo);
      if (feed == null) return null;
      final document = html_parser.parse(feed);
      final entries = document.querySelectorAll('entry');

      for (final entry in entries) {
        final link = entry.querySelector('link[rel="alternate"]') ??
            entry.querySelector('link');
        final href = link?.attributes['href'];
        final tag = href == null
            ? null
            : RegExp(r'/releases/tag/(.+?)(?:\?|#|$)')
                .firstMatch(href)
                ?.group(1);
        if (tag == null || tag.isEmpty) continue;

        final title = entry.querySelector('title')?.text.trim() ?? '';
        final version = _displayVersion(tag, title);
        if (!_sameVersion(version, preferredVersion)) continue;

        final encodedBody = entry.querySelector('content')?.text.trim();
        String? releaseNotes;
        if (encodedBody != null && encodedBody.isNotEmpty) {
          final bodyDocument = html_parser.parseFragment(encodedBody);
          final text = (bodyDocument.text ?? '')
              .replaceAll(RegExp(r'[ \t]+'), ' ')
              .replaceAll(RegExp(r'\n{3,}'), '\n\n')
              .trim();
          if (text.isNotEmpty) releaseNotes = text;
        }

        final publishedAt = _parseDate(
          entry.querySelector('updated')?.text.trim(),
        );

        return VersionInfo(
          emulatorId: emulator.id,
          version: version,
          releaseDate: publishedAt,
          releaseNotes: releaseNotes,
          isNew: false,
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 读取 GitHub 官方 Atom Feed，并按 entry.updated 的最大值选最新版。
  ///
  /// Feed 和 Releases 页面都可能把被标为 Latest 的稳定版放在上方，而
  /// 时间更晚的 nightly 位于其后；因此必须遍历全部 entry 后再决定。
  Future<VersionInfo?> _fetchLatestPublishedReleaseFromAtom(
    Emulator emulator,
    String owner,
    String repo,
  ) async {
    try {
      final feed = await _fetchAtomFeed(owner, repo);
      if (feed == null) return null;
      final document = html_parser.parse(feed);
      final entries = document.querySelectorAll('entry');
      if (entries.isEmpty) return null;

      Element? selectedEntry;
      DateTime? selectedDate;
      for (final entry in entries) {
        final link = entry.querySelector('link[rel="alternate"]') ??
            entry.querySelector('link');
        final href = link?.attributes['href'];
        final tag = href == null
            ? null
            : RegExp(r'/releases/tag/(.+?)(?:\?|#|$)')
                .firstMatch(href)
                ?.group(1);
        if (tag == null || tag.isEmpty) continue;

        final publishedAt = _parseDate(
          entry.querySelector('updated')?.text.trim(),
        );
        if (selectedEntry == null ||
            (publishedAt != null &&
                (selectedDate == null || publishedAt.isAfter(selectedDate)))) {
          selectedEntry = entry;
          selectedDate = publishedAt;
        }
      }

      final entry = selectedEntry;
      if (entry == null) return null;
      final link = entry.querySelector('link[rel="alternate"]') ??
          entry.querySelector('link');
      final href = link?.attributes['href'];
      final tag = href == null
          ? null
          : RegExp(r'/releases/tag/(.+?)(?:\?|#|$)')
              .firstMatch(href)
              ?.group(1);
      if (tag == null || tag.isEmpty) return null;

      final title = entry.querySelector('title')?.text.trim() ?? '';
      final version = _displayVersion(tag, title);
      if (version.isEmpty) return null;

      final encodedBody = entry.querySelector('content')?.text.trim();
      String? releaseNotes;
      if (encodedBody != null && encodedBody.isNotEmpty) {
        final bodyDocument = html_parser.parseFragment(encodedBody);
        final text = (bodyDocument.text ?? '')
            .replaceAll(RegExp(r'[ \t]+'), ' ')
            .replaceAll(RegExp(r'\n{3,}'), '\n\n')
            .trim();
        if (text.isNotEmpty) releaseNotes = text;
      }

      var apkUrl = await _fetchApkUrlFromExpandedAssets(owner, repo, tag);
      apkUrl ??= _buildDynamicDownloadUrl(emulator, owner, repo, tag);
      apkUrl ??= 'https://github.com/$owner/$repo/releases/tag/$tag';

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: selectedDate,
        releaseNotes: releaseNotes,
        isNew: false,
        downloadUrl: apkUrl,
      );
    } catch (_) {
      return null;
    }
  }

  /// 从同一 Atom Feed 中取第一个可明确识别的 prerelease/nightly。
  Future<({String? version, String? apkUrl, String? body, DateTime? publishedAt})?> _fetchPrereleaseInfoFromAtom(
    String owner,
    String repo,
  ) async {
    try {
      final feed = await _fetchAtomFeed(owner, repo);
      if (feed == null) return null;
      final document = html_parser.parse(feed);

      for (final entry in document.querySelectorAll('entry')) {
        final link = entry.querySelector('link[rel="alternate"]') ??
            entry.querySelector('link');
        final href = link?.attributes['href'];
        final tag = href == null
            ? null
            : RegExp(r'/releases/tag/(.+?)(?:\?|#|$)')
                .firstMatch(href)
                ?.group(1);
        if (tag == null || tag.isEmpty) continue;

        final title = entry.querySelector('title')?.text.trim() ?? '';
        final version = _displayVersion(tag, title);
        if (!_isPrereleaseTag(version.toLowerCase()) &&
            !_isPrereleaseTitle(title)) {
          continue;
        }

        final encodedBody = entry.querySelector('content')?.text.trim();
        String? body;
        if (encodedBody != null && encodedBody.isNotEmpty) {
          final bodyDocument = html_parser.parseFragment(encodedBody);
          final text = (bodyDocument.text ?? '')
              .replaceAll(RegExp(r'[ \t]+'), ' ')
              .replaceAll(RegExp(r'\n{3,}'), '\n\n')
              .trim();
          if (text.isNotEmpty) body = text;
        }

        return (
          version: version,
          apkUrl: await _fetchApkUrlFromExpandedAssets(owner, repo, tag),
          body: body,
          publishedAt: _parseDate(
            entry.querySelector('updated')?.text.trim(),
          ),
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  bool _isPrereleaseTitle(String title) {
    final normalized = title.toLowerCase();
    return RegExp(
      r'(^|\b)(nightly|preview|pre-release|prerelease|beta|alpha|snapshot|canary)(\b|$)',
    ).hasMatch(normalized) ||
        normalized.contains('release candidate') ||
        normalized.contains('预览版') ||
        normalized.contains('开发版') ||
        normalized.contains('测试版');
  }

  /// 同一轮检查中多个机种可能共用同一 GitHub 仓库。对 Atom Feed
  /// 做短时缓存，避免重复下载完全相同的内容；两分钟后自动失效，
  /// 不会影响下一次手动或后台检查发现新发布。
  Future<String?> _fetchAtomFeed(String owner, String repo) {
    final key = '${owner.toLowerCase()}/${repo.toLowerCase()}';
    final now = DateTime.now();
    final cached = _atomFeedCache[key];
    if (cached != null &&
        now.difference(cached.fetchedAt) < const Duration(minutes: 2)) {
      return cached.response;
    }

    final response = _requestAtomFeed(owner, repo);
    _atomFeedCache[key] = (fetchedAt: now, response: response);
    return response;
  }

  Future<String?> _requestAtomFeed(String owner, String repo) async {
    try {
      final response = await _dio.get(
        'https://github.com/$owner/$repo/releases.atom',
        options: _atomOptions(),
      );
      final data = response.data?.toString();
      return data == null || data.isEmpty ? null : data;
    } catch (_) {
      return null;
    }
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
  /// 严格返回页面中的第一个 release，不自行把稳定版提到前面。
  String? _extractFirstTagFromHtml(String html) {
    final tagPattern = RegExp(
      r'href="[^"]*releases/tag/([^"]+)"',
    );

    for (final match in tagPattern.allMatches(html)) {
      final tag = match.group(1)!;
      if (tag.isEmpty) continue;
      return tag;
    }
    return null;
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
    String repo, {
    bool includeCommitMessage = false,
  }) async {
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
      final body = includeCommitMessage
          ? await _resolveReleaseNotes(owner, repo, first)
          : _nonEmptyText(first['body']);

      // 从 assets 数组中提取 APK 直链
      final apkUrl = _extractApkAssetUrl(first);

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: releaseDate,
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

  /// 详情页补全：读取 GitHub 标记的最新稳定版。
  Future<VersionInfo?> _fetchFromApiLatestRelease(
    Emulator emulator,
    String owner,
    String repo,
  ) async {
    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$owner/$repo/releases/latest',
      );
      final release = _asMap(response.data);
      final tag = release['tag_name']?.toString();
      if (tag == null || tag.isEmpty) return null;

      final body = await _resolveReleaseNotes(owner, repo, release);
      return VersionInfo(
        emulatorId: emulator.id,
        version: _stripVPrefix(tag),
        releaseDate: _parseDate(release['published_at']?.toString()),
        releaseNotes: body,
        isNew: false,
        downloadUrl: _extractApkAssetUrl(release),
      );
    } catch (_) {
      return null;
    }
  }

  /// 回退方案：从 tags 接口取第一个 tag 作为最新版本。
  Future<VersionInfo?> _fetchFromTags(
    Emulator emulator,
    String owner,
    String repo, {
    bool includeCommitDetails = false,
  }) async {
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
      final commitInfo = includeCommitDetails
          ? await _fetchCommitInfo(owner, repo, tag)
          : null;

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        // tag 本身不包含日期/说明；详细检查时从其目标提交补齐。
        releaseDate: commitInfo?.date,
        releaseNotes: commitInfo?.message,
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
  /// 仅对配置了 devUrl 或 nightlyUrl 的模拟器调用，避免不必要的 API 消耗。
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

          final body = await _resolveReleaseNotes(owner, repo, release);

          return (
            version: version,
            apkUrl: apkUrl,
            body: body,
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

  /// 获取 release 更新说明。GitHub Actions 自动发布的 release 常没有
  /// body，但其 tag 指向的提交包含实际变更说明；此时读取提交 message
  /// 作为统一回退，避免 CXBX-R 等条目只有版本号而没有更新说明。
  Future<String?> _resolveReleaseNotes(
    String owner,
    String repo,
    Map<String, dynamic> release,
  ) async {
    final body = _nonEmptyText(release['body']);
    if (body != null) return body;

    final tag = _nonEmptyText(release['tag_name']);
    final target = _nonEmptyText(release['target_commitish']);
    final reference = tag ?? target;
    if (reference == null) return null;

    final commitInfo = await _fetchCommitInfo(owner, repo, reference);
    return commitInfo?.message;
  }

  Future<({DateTime? date, String? message})?> _fetchCommitInfo(
    String owner,
    String repo,
    String reference,
  ) async {
    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$owner/$repo/commits/'
        '${Uri.encodeComponent(reference)}',
      );
      final commit = _asMap(response.data);
      final details = _asMap(commit['commit']);
      final committer = _asMap(details['committer']);
      final author = _asMap(details['author']);
      return (
        date: _parseDate(
          committer['date']?.toString() ?? author['date']?.toString(),
        ),
        message: _nonEmptyText(details['message']),
      );
    } catch (_) {
      return null;
    }
  }

  String? _nonEmptyText(dynamic value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// 从 GitHub 仓库 URL 解析出 (owner, repo)。
  (String, String)? _parseRepo(String sourceUrl) {
    if (sourceUrl.isEmpty) return null;
    try {
      final uri = Uri.parse(sourceUrl);
      if ((uri.scheme != 'https' && uri.scheme != 'http') ||
          uri.host != 'github.com') {
        return null;
      }
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
    // GitHub HTML 的 href 会对中文等非 ASCII 标签进行 URL 编码。
    // 版本展示和比较必须使用可读的原始 tag，例如
    // v0.5.3_%E9%A2%84%E8%A7%88%E7%89%88 -> 0.5.3_预览版。
    try {
      v = Uri.decodeComponent(v);
    } catch (_) {
      // 编码不完整时保留原值，避免单个异常标签中断更新检查。
    }
    if (v.startsWith('v') || v.startsWith('V')) {
      v = v.substring(1);
    }
    return v;
  }

  /// 滚动发布常复用 `nightly` / `continuous` 这类固定 tag。只显示 tag 会让
  /// 每次构建看起来版本完全没变，因此从 Release 标题提取实际构建版本。
  String _displayVersion(String tag, String title) {
    final version = _stripVPrefix(tag);
    final normalized = version.toLowerCase();
    const rollingTags = <String>{
      'nightly',
      'continuous',
      'latest',
      'canary',
      'dev',
      'development',
      'preview',
    };
    if (!rollingTags.contains(normalized)) return version;

    final match = RegExp(
      r'\b(20\d{2}(?:[._-]\d{2}[._-]\d{2}|[._-]\d{4}|\d{4}))\b',
    ).firstMatch(title);
    final build = match?.group(1);
    return build == null || build.isEmpty ? version : '$normalized-$build';
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
