import 'dart:math';

import '../../data/database/database.dart';
import '../../data/models/emulator.dart';
import '../../data/models/version_info.dart';
import 'github_adapter.dart';
import 'playstore_adapter.dart';
import 'version_adapter.dart';
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

/// 更新检查编排服务。
///
/// 依赖 [CachedVersionsDao] 与三个数据源适配器（GitHub / Play Store / Website），
/// 负责按 [Emulator.sourceType] 选择适配器、并发抓取最新版本、与本地缓存对比并
/// 写回缓存，最终汇总为 [CheckResult]。
///
/// 设计要点：
/// - 并发上限可配置（默认 5），批次间插入延迟以避免触发限流；
/// - 单个模拟器检查失败不影响其它模拟器，失败项记入 [CheckResult.failed]；
/// - 适配器返回的 [VersionInfo.isNew] 一律为 false，是否为新版本由本服务结合
///   [VersionComparator] 与本地缓存判定后写入。
class UpdateService {
  UpdateService({
    required CachedVersionsDao dao,
    GitHubReleasesAdapter? githubAdapter,
    PlayStoreAdapter? playStoreAdapter,
    WebsiteAdapter? websiteAdapter,
    int maxConcurrency = 5,
    Duration requestDelay = const Duration(milliseconds: 800),
  })  : _dao = dao,
        _githubAdapter = githubAdapter ?? GitHubReleasesAdapter(),
        _playStoreAdapter = playStoreAdapter ?? PlayStoreAdapter(),
        _websiteAdapter = websiteAdapter ?? WebsiteAdapter(),
        _maxConcurrency = maxConcurrency,
        _requestDelay = requestDelay;

  final CachedVersionsDao _dao;
  final GitHubReleasesAdapter _githubAdapter;
  final PlayStoreAdapter _playStoreAdapter;
  final WebsiteAdapter _websiteAdapter;
  final int _maxConcurrency;
  final Duration _requestDelay;

  /// 根据 sourceType 选择适配器。
  VersionAdapter _selectAdapter(Emulator emulator) {
    switch (emulator.sourceType) {
      case 'github':
        return _githubAdapter;
      case 'playstore':
        return _playStoreAdapter;
      case 'website':
        return _websiteAdapter;
      default:
        return _websiteAdapter;
    }
  }

  /// 检查全部模拟器的更新。
  ///
  /// 按 [_maxConcurrency] 将模拟器分批，每批内并发请求；批次之间插入
  /// [_requestDelay] 延迟以降低被限流的风险。单个失败不影响其它项。
  Future<CheckResult> checkAll(List<Emulator> emulators) async {
    final updated = <VersionInfo>[];
    final failed = <String>[];
    var checked = 0;

    // 分批
    final batches = <List<Emulator>>[];
    for (var i = 0; i < emulators.length; i += _maxConcurrency) {
      final end = min(i + _maxConcurrency, emulators.length);
      batches.add(emulators.sublist(i, end));
    }

    for (var batchIndex = 0; batchIndex < batches.length; batchIndex++) {
      // 批次间延迟避免限流
      if (batchIndex > 0) {
        await Future.delayed(_requestDelay);
      }
      final batch = batches[batchIndex];

      // 批内并发
      final outcomes = await Future.wait(
        batch.map((emulator) => _checkOneInternal(emulator)),
      );

      for (final outcome in outcomes) {
        if (!outcome.success) {
          failed.add(outcome.emulatorId);
          continue;
        }
        checked++;
        final info = outcome.versionInfo;
        if (info != null && info.isNew) {
          updated.add(info);
        }
      }
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
    final outcome = await _checkOneInternal(emulator);
    return outcome.versionInfo;
  }

  /// 单个模拟器检查的内部实现。
  ///
  /// 抓取最新版本后与本地缓存对比：若本地无缓存，视为新版本；否则使用
  /// [VersionComparator.isNewer] 判断。最终写回缓存。
  Future<_CheckOutcome> _checkOneInternal(Emulator emulator) async {
    try {
      final adapter = _selectAdapter(emulator);
      final latest = await adapter.fetchLatestVersion(emulator);
      if (latest == null) {
        return _CheckOutcome(
          emulatorId: emulator.id,
          success: false,
          versionInfo: null,
        );
      }

      final cached = await _dao.getCachedVersion(emulator.id);
      final bool isNew;
      if (cached == null) {
        // 本地无缓存，视为新版本
        isNew = true;
      } else if (cached.currentVersion.isEmpty) {
        isNew = true;
      } else {
        isNew = VersionComparator.isNewer(
          cached.currentVersion,
          latest.version,
        );
      }

      final versionInfo = VersionInfo(
        emulatorId: latest.emulatorId,
        version: latest.version,
        releaseDate: latest.releaseDate,
        releaseNotes: latest.releaseNotes,
        isNew: isNew,
      );

      await _dao.upsertFromVersionInfo(versionInfo);

      return _CheckOutcome(
        emulatorId: emulator.id,
        success: true,
        versionInfo: versionInfo,
      );
    } catch (_) {
      // 单个失败不影响其它模拟器
      return _CheckOutcome(
        emulatorId: emulator.id,
        success: false,
        versionInfo: null,
      );
    }
  }

  /// 返回当前缓存中存在新版本（isNew = true）的 [VersionInfo] 列表。
  ///
  /// 供 UI 层展示“有更新的模拟器列表”使用。
  Future<List<VersionInfo>> getUpdatesSummary() async {
    final cached = await _dao.getAllCachedVersions();
    return cached
        .where((c) => c.isNew)
        .map(
          (c) => VersionInfo(
            emulatorId: c.emulatorId,
            version: c.currentVersion,
            releaseDate: c.lastReleaseDate != null
                ? DateTime.fromMillisecondsSinceEpoch(c.lastReleaseDate!)
                : DateTime.now(),
            releaseNotes: c.releaseNotes,
            isNew: true,
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
  });

  final String emulatorId;

  /// 是否成功获取到版本信息并写回缓存。
  final bool success;

  /// 检查得到的版本信息，失败时为 `null`。
  final VersionInfo? versionInfo;
}
