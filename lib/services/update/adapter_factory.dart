import '../../data/models/emulator.dart';
import 'github_adapter.dart';
import 'playstore_adapter.dart';
import 'version_adapter.dart';
import 'website_adapter.dart';

/// 适配器工厂。
///
/// 根据 [Emulator.sourceType] 创建对应的数据源适配器实例：
/// - `github` -> [GitHubReleasesAdapter]
/// - `playstore` -> [PlayStoreAdapter]
/// - `website` -> [WebsiteAdapter]
/// - 未知类型 -> [WebsiteAdapter]（兜底）
class AdapterFactory {
  AdapterFactory._();

  /// 根据模拟器的 [Emulator.sourceType] 返回对应的适配器实例。
  static VersionAdapter create(Emulator emulator) {
    switch (emulator.sourceType) {
      case 'github':
        return GitHubReleasesAdapter();
      case 'playstore':
        return PlayStoreAdapter();
      case 'website':
        return WebsiteAdapter();
      default:
        return WebsiteAdapter();
    }
  }
}
