import 'dart:math';

import '../../data/database/database.dart';
import '../../data/models/emulator.dart';
import '../../data/models/version_info.dart';
import 'forgejo_adapter.dart';
import 'github_adapter.dart';
import 'gitlab_adapter.dart';
import 'playstore_adapter.dart';
import 'version_adapter.dart';
import 'version_catalog_service.dart';
import 'version_comparator.dart';
import 'website_adapter.dart';

/// 一次更新检查的结果。
class CheckResult {
  CheckResult({
    required this.checked,
    required this.updated,
    required this.failed,
    required this.timestamp,
  });

  /// 本次检查覆盖的模拟器数量（成功完成检查流程）。
  final int checked;

  /// 检测到新版本的 [VersionInfo] 列表（isNew = true）。
  final List<VersionInfo> updated;

  /// 检查失败的模拟器 id 列表（请求异常或无法解析版本）。
  final List<String> failed;

  /// 本次检查完成时间。
  final DateTime timestamp;

  /// 是否存在新版本。
  bool get hasUpdates => updated.isNotEmpty;
}

/// Incremental progress emitted after each completed request batch.
class CheckProgress {
  const CheckProgress({required this.completed, required this.total});

  final int completed;
  final int total;
}

/// 更新检查编排服务。
///
/// 依赖 [CachedVersionsDao] 与五个数据源适配器（GitHub / GitLab / Forgejo / Play Store / Website），
/// 负责按 [Emulator.sourceType] 选择适配器、并发抓取最新版本、与本地缓存对比并
/// 写回缓存，最终汇总为 [CheckResult]。
///
/// 设计要点：
/// - 并发上限可配置（默认 10），批次间插入短延迟以避免触发限流；
/// - 单个模拟器检查失败不影响其它模拟器，失败项记入 [CheckResult.failed]；
/// - Play Store 等非代码托管来源抓取失败时，自动尝试 website 适配器作为回退；
///   GitHub / GitLab / Forgejo 失败时不会把官网页面的无关版本号写入缓存；
/// - 只要条目配置了 [Emulator.playStoreId]，都会补充 Google Play 的
///   发布日期与“新变化”，不受主更新源类型限制；
/// - 适配器返回的 [VersionInfo.isNew] 一律为 false；只有远端发布日期
///   同时晚于可信缓存日期和上次成功检查时间才标记新版本，版本比较仅用于
///   静默修复缓存，避免后来补识别的历史 Release 产生误报。
class UpdateService {
  UpdateService({
    required CachedVersionsDao dao,
    VersionAdapter? githubAdapter,
    VersionAdapter? gitlabAdapter,
    VersionAdapter? forgejoAdapter,
    VersionAdapter? playStoreAdapter,
    VersionAdapter? websiteAdapter,
    VersionCatalogService? versionCatalog,
    int maxConcurrency = 10,
    Duration requestDelay = const Duration(milliseconds: 150),
    int maxFetchAttempts = 2,
    Duration retryDelay = const Duration(milliseconds: 500),
  })  : _dao = dao,
        _githubAdapter = githubAdapter ?? GitHubReleasesAdapter(),
        _gitlabAdapter = gitlabAdapter ?? GitLabReleasesAdapter(),
        _forgejoAdapter = forgejoAdapter ?? ForgejoReleasesAdapter(),
        _playStoreAdapter = playStoreAdapter ?? PlayStoreAdapter(),
        _websiteAdapter = websiteAdapter ?? WebsiteAdapter(),
        _versionCatalog = versionCatalog,
        _maxConcurrency = maxConcurrency,
        _requestDelay = requestDelay,
        _maxFetchAttempts = maxFetchAttempts,
        _retryDelay = retryDelay;

  final CachedVersionsDao _dao;
  final VersionAdapter _githubAdapter;
  final VersionAdapter _gitlabAdapter;
  final VersionAdapter _forgejoAdapter;
  final VersionAdapter _playStoreAdapter;
  final VersionAdapter _websiteAdapter;
  final VersionCatalogService? _versionCatalog;
  final int _maxConcurrency;
  final Duration _requestDelay;
  final int _maxFetchAttempts;
  final Duration _retryDelay;

  /// 根据 sourceType 选择适配器。
  ///
  /// 增加智能回退：如果 sourceType 是 github/gitlab 但 sourceUrl 不匹配
  /// 对应平台域名，自动回退到 website 适配器。
  VersionAdapter _selectAdapter(Emulator emulator) {
    switch (emulator.sourceType) {
      case 'github':
        // GitHub 类型但 URL 不是 github.com → 回退到 website
        if (emulator.sourceUrl.isNotEmpty &&
            !_hasHost(emulator.sourceUrl, 'github.com')) {
          return _websiteAdapter;
        }
        return _githubAdapter;
      case 'gitlab':
        final gitlabUri = Uri.tryParse(emulator.sourceUrl);
        if (gitlabUri == null ||
            (gitlabUri.scheme != 'https' && gitlabUri.scheme != 'http') ||
            gitlabUri.host.isEmpty) {
          return _websiteAdapter;
        }
        return _gitlabAdapter;
      case 'forgejo':
        return _forgejoAdapter;
      case 'playstore':
        return _playStoreAdapter;
      case 'website':
        return _websiteAdapter;
      default:
        return _websiteAdapter;
    }
  }

  bool _hasHost(String url, String expectedHost) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        (uri.host == expectedHost || uri.host.endsWith('.$expectedHost'));
  }

  /// 检查全部模拟器的更新。
  ///
  /// 按 [_maxConcurrency] 将模拟器分批，每批内并发请求；批次之间插入
  /// [_requestDelay] 延迟以降低被限流的风险。检查时一次性获取版本号、
  /// 发布日期、更新说明及下载地址，详情页只读取这里写入的缓存。
  /// 单个失败不影响其它项。
  Future<CheckResult> checkAll(
    List<Emulator> emulators, {
    bool reconcileUnread = false,
    void Function(CheckProgress progress)? onProgress,
  }) async {
    final updated = <VersionInfo>[];
    final failed = <String>[];
    final sharedFetches = <String, Future<VersionInfo?>>{};
    var checked = 0;

    // 聚合目录可瞬间返回绝大部分 GitHub 条目。优先处理它们，避免少数
    // 官网/商店超时把前面的批次卡住，用户可以先看到已有版本逐批回填。
    Set<String> catalogIds = const <String>{};
    if (_versionCatalog != null) {
      try {
        catalogIds = await _versionCatalog.availableEmulatorIds();
      } catch (_) {
        // Direct adapters remain available when catalog loading fails.
      }
    }

    final orderedEmulators = List<Emulator>.of(emulators)
      ..sort((a, b) {
        int priority(Emulator emulator) {
          if (catalogIds.contains(emulator.id) &&
              emulator.playStoreId.isEmpty) {
            return 0;
          }
          if (catalogIds.contains(emulator.id)) return 1;
          if (emulator.sourceType == 'github') return 2;
          return 3;
        }

        final aPriority = priority(a);
        final bPriority = priority(b);
        return aPriority.compareTo(bPriority);
      });

    // 分批
    final batches = <List<Emulator>>[];
    for (var i = 0; i < orderedEmulators.length; i += _maxConcurrency) {
      final end = min(i + _maxConcurrency, orderedEmulators.length);
      batches.add(orderedEmulators.sublist(i, end));
    }

    for (var batchIndex = 0; batchIndex < batches.length; batchIndex++) {
      // 批次间延迟避免限流
      if (batchIndex > 0) {
        await Future.delayed(_requestDelay);
      }
      final batch = batches[batchIndex];

      // 批内并发
      final outcomes = await Future.wait(
        batch.map(
          (emulator) => _checkOneInternal(
            emulator,
            sharedFetches: sharedFetches,
            includeDetails: true,
            reconcileUnread: reconcileUnread,
          ),
        ),
      );

      for (final outcome in outcomes) {
        if (!outcome.success) {
          failed.add(outcome.emulatorId);
          continue;
        }
        checked++;
        final info = outcome.versionInfo;
        if (info != null && outcome.detectedUpdate) {
          updated.add(info);
        }
      }
      onProgress?.call(
        CheckProgress(
          completed: min((batchIndex + 1) * _maxConcurrency, emulators.length),
          total: emulators.length,
        ),
      );
    }

    return CheckResult(
      checked: checked,
      updated: updated,
      failed: failed,
      timestamp: DateTime.now(),
    );
  }

  /// 检查单个模拟器的更新，返回带 isNew 标记的 [VersionInfo]。
  ///
  /// 返回 `null` 表示抓取失败或无可用版本。
  Future<VersionInfo?> checkOne(Emulator emulator) async {
    final outcome = await _checkOneInternal(
      emulator,
      includeDetails: true,
      forceDetails: true,
      allowCatalog: false,
    );
    return outcome.versionInfo;
  }

  /// 单个模拟器检查的内部实现。
  ///
  /// 抓取最新版本后与本地缓存对比：首次检查只建立基线；已有
  /// 基线时，只有远端发布日期严格更新才产生更新提示。最终写回缓存。
  ///
  /// 如果主适配器返回 null，尝试使用 website 适配器作为回退。
  Future<_CheckOutcome> _checkOneInternal(
    Emulator emulator, {
    Map<String, Future<VersionInfo?>>? sharedFetches,
    bool includeDetails = false,
    bool forceDetails = false,
    bool reconcileUnread = false,
    bool allowCatalog = true,
  }) async {
    try {
      final adapter = _selectAdapter(emulator);
      final requestKey = _requestKey(emulator, adapter);
      final cached = await _dao.getCachedVersion(emulator.id);

      // 先轻量获取版本号。批量检查只在版本变化、首次检查、已有元数据
      // 缺失/可疑时再抓完整 Release 页面，兼顾完整性和请求数量。
      final fetch = sharedFetches?.putIfAbsent(
            requestKey,
            () => _fetchLatestWithRetry(
              emulator,
              adapter,
              includeDetails: false,
              allowCatalog: allowCatalog,
            ),
          ) ??
          _fetchLatestWithRetry(
            emulator,
            adapter,
            includeDetails: false,
            allowCatalog: allowCatalog,
          );
      var latest = await fetch;

      if (latest != null &&
          includeDetails &&
          adapter.adapterName == 'github' &&
          (forceDetails || _needsDetailedFetch(cached, latest))) {
        final detailsKey = '$requestKey\u0000details';
        final detailedFetch = sharedFetches?.putIfAbsent(
              detailsKey,
              () => _fetchLatestWithRetry(
                emulator,
                adapter,
                includeDetails: true,
                allowCatalog: allowCatalog,
              ),
          ) ??
            _fetchLatestWithRetry(
              emulator,
              adapter,
              includeDetails: true,
              allowCatalog: allowCatalog,
            );
        final detailed = await detailedFetch;
        if (detailed != null) latest = detailed;
      }

      // Google Play 是独立的发布渠道。此前仅 sourceType=playstore 的条目
      // 会读取商店“新变化”，导致 GitHub/GitLab 作为主更新源、但同样提供
      // Google Play 下载的模拟器缺少发布日期和更新说明。
      //
      // 在完整检查时，所有设置了 playStoreId 的条目均补抓 Play 元数据；
      // 版本号仍优先以主更新源为准。多个机种若复用同一个 Play 包名，则
      // 共享同一次请求，避免放大商店请求量。
      if (includeDetails &&
          emulator.playStoreId.isNotEmpty &&
          adapter.adapterName != 'playstore') {
        final playMetadataKey = _playStoreMetadataRequestKey(emulator);
        final metadataFetch = sharedFetches?.putIfAbsent(
              playMetadataKey,
              () => _fetchPlayStoreMetadataWithRetry(emulator),
            ) ??
            _fetchPlayStoreMetadataWithRetry(emulator);
        final playMetadata = await metadataFetch;
        latest = _mergePlayStoreMetadata(latest, playMetadata);
      }

      // 同一数据源的结果可供多个机种条目复用，但每条缓存仍使用自己的 id。
      if (latest != null && latest.emulatorId != emulator.id) {
        latest = latest.copyWith(emulatorId: emulator.id);
      }

      if (latest == null) {
        return _CheckOutcome(
          emulatorId: emulator.id,
          success: false,
          versionInfo: null,
          detectedUpdate: false,
        );
      }

      // Google Play 可能在后续页面改版中停止公开版本号。若本地已有可信
      // 版本，保留该版本并刷新商店日期/说明，避免把缓存降级为空字符串。
      if (cached != null &&
          latest.version.trim().isEmpty &&
          cached.currentVersion.trim().isNotEmpty) {
        latest = latest.copyWith(version: cached.currentVersion);
      }

      late final VersionInfo versionInfo;
      var detectedUpdate = false;

      if (cached == null) {
        // 本地无缓存：本次为首次检查，仅建立版本基线，不标记为新版本。
        // 否则首次运行会把全部模拟器标记为“有更新”并群发通知。
        versionInfo = latest.copyWith(isNew: false);
      } else {
        // 只要两侧都有精确发布日期，发布时间就是跨稳定版、开发版和
        // nightly 的唯一排序依据。这样不会把 nightly-20260803 和 2.6.6.3
        // 这类完全不同格式的标签拿来做字符串/语义版本比较。
        // 缺少日期时才回退到既有的版本比较，兼容官网和商店等数据源。
        final recency = _compareRecency(cached, latest);
        final latestIsNewer = recency > 0;
        final cachedIsNewer = recency < 0;
        final hasNewerReleaseDate = _hasNewerReleaseDate(cached, latest);

        if (cachedIsNewer) {
          // 远端偶尔会因 latest 标记、镜像同步或解析回退而返回旧版本。
          // 此时仅刷新检查时间，绝不能把本地版本和下载链接降级。
          await _dao.touchLastChecked(emulator.id);
          if (reconcileUnread && cached.isNew) {
            await _dao.markAsSeen(emulator.id);
          }
          versionInfo = _versionInfoFromCache(cached).copyWith(
            isNew: reconcileUnread ? false : cached.isNew,
          );
        } else {
          // “有更新”只由可信的发布日期决定：远端日期必须严格晚于缓存
          // 日期及上次成功检查时间。缓存缺少日期或后来才补识别到历史版本
          // 时属于元数据修复，静默写回但不提示更新；仅版本号变化或标签
          // 格式变化也不会产生误报。
          detectedUpdate = hasNewerReleaseDate;
          versionInfo = latest.copyWith(
            // 相同版本再次检查时保留“未读”状态；只有详情页明确查看后
            // 才由 markAsSeen 清除，避免提示自动消失。
            // 用户手动复检时则以本轮结果为准：未发现更新就清除
            // 历史遗留的假未读标记。后台检查仍保留原有未读语义。
            isNew: hasNewerReleaseDate ||
                (!reconcileUnread && cached.isNew),
            // 轻量检查无法获知发布日期时，不得用检查时间覆盖真实日期。
            // 详情检查拿到日期后会自动补全缓存。
            releaseDate: latestIsNewer
                ? latest.releaseDate
                : latest.releaseDate ?? _releaseDateFromCache(cached),
            // 同版本抓取偶发缺字段时保留此前解析成功的数据。
            releaseNotes: latestIsNewer
                ? latest.releaseNotes
                : latest.releaseNotes ?? cached.releaseNotes,
            downloadUrl: latestIsNewer
                ? latest.downloadUrl
                : latest.downloadUrl ?? cached.resolvedDownloadUrl,
            devDownloadUrl: latestIsNewer
                ? latest.devDownloadUrl
                : latest.devDownloadUrl ?? cached.resolvedDevDownloadUrl,
            devReleaseNotes: latestIsNewer
                ? latest.devReleaseNotes
                : latest.devReleaseNotes ?? cached.resolvedDevReleaseNotes,
          );
          await _dao.upsertFromVersionInfo(versionInfo);
        }
      }

      if (cached == null) {
        await _dao.upsertFromVersionInfo(versionInfo);
      }

      return _CheckOutcome(
        emulatorId: emulator.id,
        success: true,
        versionInfo: versionInfo,
        detectedUpdate: detectedUpdate,
      );
    } catch (_) {
      // 单个失败不影响其它模拟器
      return _CheckOutcome(
        emulatorId: emulator.id,
        success: false,
        versionInfo: null,
        detectedUpdate: false,
      );
    }
  }

  bool _needsDetailedFetch(CachedVersion? cached, VersionInfo latest) {
    if (cached == null) return true;
    if (VersionComparator.isNewer(cached.currentVersion, latest.version) ||
        VersionComparator.isNewer(latest.version, cached.currentVersion)) {
      return true;
    }
    if (cached.lastReleaseDate == null || cached.releaseNotes == null) {
      return true;
    }

    // 旧版本曾把检查时间写成发布日期；两者几乎相同即视为待修复数据。
    return _hasSuspiciousCachedReleaseDate(cached);
  }

  int _compareRecency(CachedVersion cached, VersionInfo latest) {
    final cachedDate = _trustedCachedReleaseDate(cached);
    final latestDate = latest.releaseDate?.millisecondsSinceEpoch;
    if (latestDate != null) {
      // 远端已有可信发布日期而旧缓存没有日期时，允许静默修复错误版本与
      // 元数据；是否提示更新由 [_hasNewerReleaseDate] 单独决定。
      if (cachedDate == null) return 1;
      if (latestDate != cachedDate) {
        return latestDate.compareTo(cachedDate);
      }
    } else if (cachedDate != null) {
      // 临时解析失败不能用无日期结果覆盖已经确认的有日期缓存。
      return -1;
    }

    if (VersionComparator.isNewer(cached.currentVersion, latest.version)) {
      return 1;
    }
    if (VersionComparator.isNewer(latest.version, cached.currentVersion)) {
      return -1;
    }
    return 0;
  }

  bool _hasNewerReleaseDate(CachedVersion cached, VersionInfo latest) {
    final cachedDate = _trustedCachedReleaseDate(cached);
    final latestDate = latest.releaseDate?.millisecondsSinceEpoch;
    return cachedDate != null &&
        latestDate != null &&
        latestDate > cachedDate &&
        // 版本源之前漏抓、后来才补识别的历史 Release 只用于静默修复缓存。
        // 只有上次成功检查之后真正发布的版本才应通知用户。
        latestDate > cached.lastCheckedAt;
  }

  /// 旧版曾把“检查时间”当作“发布时间”写入。两者几乎
  /// 相同的行不能用来判断新旧，否则真实但更早的发布日期会被
  /// 误判为远端回退，永远无法修复。
  int? _trustedCachedReleaseDate(CachedVersion cached) =>
      _hasSuspiciousCachedReleaseDate(cached)
          ? null
          : cached.lastReleaseDate;

  bool _hasSuspiciousCachedReleaseDate(CachedVersion cached) {
    final releaseDate = cached.lastReleaseDate;
    if (releaseDate == null) return false;
    final difference = (cached.lastCheckedAt - releaseDate).abs();
    return difference <= const Duration(minutes: 5).inMilliseconds;
  }

  /// 在一次用户触发的检查中，对临时网络失败自动重试。
  ///
  /// 适配器会将超时、限流和短暂的页面解析失败统一表现为 `null`，此前这些
  /// 项目会直接被标记失败，用户必须再次点击才能补全。重试 Future 仍由
  /// [sharedFetches] 共享，因此相同来源只会重试一次，不会放大请求量。
  Future<VersionInfo?> _fetchLatestWithRetry(
    Emulator emulator,
    VersionAdapter adapter, {
    required bool includeDetails,
    bool allowCatalog = true,
  }) async {
    // GitHub Actions has already reduced all GitHub releases to one catalog,
    // selecting the newest real publication time. This turns 261 per-repository
    // page downloads into a single shared JSON request. A missing/stale entry
    // never blocks the legacy adapter fallback below.
    if (allowCatalog &&
        adapter.adapterName == 'github' &&
        _versionCatalog != null) {
      try {
        final catalogVersion = await _versionCatalog.lookup(emulator);
        if (catalogVersion != null) return catalogVersion;
      } catch (_) {
        // Fall through to direct source checks.
      }
    }

    final attempts = max(1, _maxFetchAttempts);

    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        final latest = await _fetchLatestWithFallback(
          emulator,
          adapter,
          includeDetails: includeDetails,
        );
        if (latest != null) return latest;
      } catch (_) {
        // 与适配器返回 null 的临时失败统一走退避重试。
      }

      if (attempt + 1 < attempts) {
        await Future<void>.delayed(
          Duration(milliseconds: _retryDelay.inMilliseconds * (attempt + 1)),
        );
      }
    }

    return null;
  }

  /// 抓取 Google Play 的补充元数据，不触发 website/download 回退。
  ///
  /// 这与 [_fetchLatestWithRetry] 分开，防止主更新源为 GitHub 等情况时，
  /// Google Play 元数据请求又错误地触发一轮官网版本抓取。
  Future<VersionInfo?> _fetchPlayStoreMetadataWithRetry(
    Emulator emulator,
  ) async {
    final attempts = max(1, _maxFetchAttempts);

    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        final metadata = await _playStoreAdapter.fetchLatestVersion(
          emulator,
          includeDetails: true,
        );
        if (metadata != null) return metadata;
      } catch (_) {
        // 与主更新检查保持一致：短暂网络异常自动重试。
      }

      if (attempt + 1 < attempts) {
        await Future<void>.delayed(
          Duration(milliseconds: _retryDelay.inMilliseconds * (attempt + 1)),
        );
      }
    }

    return null;
  }

  /// 执行主数据源抓取及两级回退。
  Future<VersionInfo?> _fetchLatestWithFallback(
    Emulator emulator,
    VersionAdapter adapter, {
    required bool includeDetails,
  }) async {
    var latest = await adapter.fetchLatestVersion(
      emulator,
      includeDetails: includeDetails,
    );

    // Google Play 的现代页面可能只有更新日期和“新变化”，没有独立版本号。
    // 暂存这些元数据，再使用官网或下载地址解析版本，最后合并为完整结果。
    VersionInfo? metadataOnly;
    if (latest != null && latest.version.trim().isEmpty) {
      metadataOnly = latest;
      latest = null;
    }

    // GitHub / GitLab / Forgejo 的官网通常会同时包含站点、文档或应用壳
    // 的版本号；当 release 请求临时失败时，把网页中第一个 `1.0` 一类
    // 数字写入缓存会污染真实模拟器版本。代码托管源只信任其 release
    // 结果或明确下载链接；Play/官网型来源仍保留网页回退。
    const codeHostingSources = <String>{
      'github',
      'gitlab',
      'forgejo',
    };
    final allowsWebsiteFallback =
        !codeHostingSources.contains(emulator.sourceType);
    if (latest == null &&
        allowsWebsiteFallback &&
        emulator.website.isNotEmpty &&
        adapter.adapterName != 'website') {
      latest = await _websiteAdapter.fetchLatestVersion(
        emulator,
        includeDetails: includeDetails,
      );
    }

    if (latest == null && emulator.downloadUrl.isNotEmpty) {
      latest = await _tryFromDownloadUrl(emulator);
    }

    if (latest != null && metadataOnly != null) {
      latest = latest.copyWith(
        releaseDate: metadataOnly.releaseDate ?? latest.releaseDate,
        releaseNotes: metadataOnly.releaseNotes ?? latest.releaseNotes,
      );
    }

    // 没有官网版本回退时仍保存 Play 的日期和更新说明。版本号为空是
    // “商店未公开版本号”，不代表整次抓取失败。
    return latest ?? metadataOnly;
  }

  /// 合并主更新源与 Google Play 时，始终选择发布时间更晚的一侧。
  ///
  /// 这让 GitHub、GitLab、官网和商店渠道都遵循相同的“最新发布优先”
  /// 规则；若 Play 没有版本号，只替换发布日期与更新说明，保留主源版本。
  VersionInfo? _mergePlayStoreMetadata(
    VersionInfo? latest,
    VersionInfo? playMetadata,
  ) {
    if (playMetadata == null) return latest;

    if (latest == null) {
      return playMetadata;
    }

    final playDate = playMetadata.releaseDate;
    final primaryDate = latest.releaseDate;
    final shouldUsePlay = playDate != null &&
        (primaryDate == null || playDate.isAfter(primaryDate));

    if (!shouldUsePlay) return latest;

    return latest.copyWith(
      version: playMetadata.version.trim().isNotEmpty
          ? playMetadata.version
          : latest.version,
      releaseDate: playDate,
      releaseNotes: playMetadata.releaseNotes ?? latest.releaseNotes,
    );
  }

  /// 一次批量检查中可复用请求的键。
  ///
  /// 将所有会影响主抓取及回退结果的字段纳入键中，既消除同源重复请求，
  /// 又避免下载模板不同的条目错误共享结果。
  String _requestKey(Emulator emulator, VersionAdapter adapter) {
    return <String>[
      adapter.adapterName,
      emulator.sourceUrl,
      emulator.playStoreId,
      emulator.website,
      emulator.downloadUrl,
      emulator.devUrl,
      emulator.nightlyUrl,
    ].join('\u0000');
  }

  /// Google Play 的结果只由包名决定，可供同包名的不同机种条目复用。
  String _playStoreMetadataRequestKey(Emulator emulator) =>
      'playstore-metadata\u0000${emulator.playStoreId}';

  VersionInfo _versionInfoFromCache(CachedVersion cached) {
    return VersionInfo(
      emulatorId: cached.emulatorId,
      version: cached.currentVersion,
      releaseDate: _releaseDateFromCache(cached),
      releaseNotes: cached.releaseNotes,
      isNew: cached.isNew,
      downloadUrl: cached.resolvedDownloadUrl,
      devDownloadUrl: cached.resolvedDevDownloadUrl,
      devReleaseNotes: cached.resolvedDevReleaseNotes,
    );
  }

  DateTime? _releaseDateFromCache(CachedVersion cached) {
    final timestamp = cached.lastReleaseDate;
    return timestamp == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(timestamp);
  }

  /// 从 downloadUrl 中尝试提取版本号作为最后手段。
  ///
  /// 适用于 downloadUrl 中包含版本号的情况，如：
  /// `https://stable.eden-emu.dev/v0.2.1/Eden-Android-v0.2.1-standard.apk`
  ///
  /// 返回的 [VersionInfo.downloadUrl] 设为原始 downloadUrl，
  /// 由 [DownloadResolver] 在 UI 层根据最新版本号动态替换。
  Future<VersionInfo?> _tryFromDownloadUrl(Emulator emulator) async {
    final url = emulator.downloadUrl;
    if (url.isEmpty) return null;

    // 尝试从 URL 路径中提取版本号
    final patterns = <RegExp>[
      // v0.2.1 或 v1.2.3
      RegExp(r'/v(\d+\.\d+(?:\.\d+)*)'),
      // version-1.2.3
      RegExp(r'version[-_]?(\d+\.\d+(?:\.\d+)*)'),
      // releases/v1.2.3
      RegExp(r'releases/v?(\d+\.\d+(?:\.\d+)*)'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(url);
      if (match != null) {
        final version = match.group(1);
        if (version != null && version.isNotEmpty) {
          return VersionInfo(
            emulatorId: emulator.id,
            version: version,
            releaseDate: null,
            releaseNotes: null,
            isNew: false,
            // 保留原始 downloadUrl，UI 层会根据最新版本动态替换
            downloadUrl: url,
          );
        }
      }
    }

    return null;
  }

  /// 返回当前缓存中存在新版本（isNew = true）的 [VersionInfo] 列表。
  ///
  /// 供 UI 层展示"有更新的模拟器列表"使用。
  Future<List<VersionInfo>> getUpdatesSummary() async {
    final cached = await _dao.getAllCachedVersions();
    return cached
        .where((c) => c.isNew)
        .map(
          (c) => VersionInfo(
            emulatorId: c.emulatorId,
            version: c.currentVersion,
            releaseDate: _releaseDateFromCache(c),
            releaseNotes: c.releaseNotes,
            isNew: true,
            // 携带适配器动态解析的下载直链，避免 UI 回退到可能 404 的静态 URL
            downloadUrl: c.resolvedDownloadUrl,
            devDownloadUrl: c.resolvedDevDownloadUrl,
            devReleaseNotes: c.resolvedDevReleaseNotes,
          ),
        )
        .toList();
  }
}

/// 单个模拟器检查的内部结果。
class _CheckOutcome {
  _CheckOutcome({
    required this.emulatorId,
    required this.success,
    required this.versionInfo,
    required this.detectedUpdate,
  });

  final String emulatorId;

  /// 是否成功获取到版本信息并写回缓存。
  final bool success;

  /// 检查得到的版本信息，失败时为 `null`。
  final VersionInfo? versionInfo;

  /// 是否在本次请求中首次检测到比缓存更新的版本。
  ///
  /// 与 [VersionInfo.isNew] 不同：后者是持久化的未读状态；本字段仅用于
  /// 决定本次是否需要发送通知，避免相同未读版本在每轮检查时重复通知。
  final bool detectedUpdate;
}
