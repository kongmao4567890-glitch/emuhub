import '../../data/models/emulator.dart';
import '../../data/models/version_info.dart';

/// 版本来源适配器抽象基类。
///
/// 不同更新来源（GitHub Release / Play Store / 官网页面）各自实现
/// [fetchLatestVersion]，从对应渠道抓取最新版本信息并返回 [VersionInfo]。
///
/// 约定：
/// - 返回的 [VersionInfo.isNew] 一律为 `false`，是否为新版本由上层
///   [UpdateService] / [VersionComparator] 与本地缓存对比后决定。
/// - 抓取失败或无法解析时返回 `null`，不应抛出异常。
abstract class VersionAdapter {
  /// 适配器名称，用于日志与调试，例如 `github` / `playstore` / `website`。
  String get adapterName;

  /// 抓取指定 [emulator] 的最新版本信息。
  ///
  /// 成功时返回 [VersionInfo]；失败或无可用数据时返回 `null`。
  Future<VersionInfo?> fetchLatestVersion(Emulator emulator);
}
