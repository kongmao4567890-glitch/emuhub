import '../../data/models/emulator.dart';
import 'forgejo_adapter.dart';
import 'github_adapter.dart';
import 'gitlab_adapter.dart';
import 'playstore_adapter.dart';
import 'version_adapter.dart';
import 'website_adapter.dart';

/// 适配器工厂。
///
/// 根据 [Emulator.sourceType] 创建对应的数据源适配器实例：
/// - `github` -> [GitHubReleasesAdapter]
/// - `gitlab` -> [GitLabReleasesAdapter]
/// - `forgejo` -> [ForgejoReleasesAdapter]
/// - `playstore` -> [PlayStoreAdapter]
/// - `website` -> [WebsiteAdapter]
/// - 未知类型 -> [WebsiteAdapter]（兜底）
///
/// 注意：与 [UpdateService] 的智能回退不同，本工厂不做 URL 域名校验；
/// 调用方若需要“sourceType 与 sourceUrl 域名不匹配时回退 website”
/// 的行为，应使用 [UpdateService]。
class AdapterFactory {
  AdapterFactory._();

  /// 根据模拟器的 [Emulator.sourceType] 返回对应的适配器实例。
  static VersionAdapter create(Emulator emulator) {
    switch (emulator.sourceType) {
      case 'github':
        return GitHubReleasesAdapter();
      case 'gitlab':
        return GitLabReleasesAdapter();
      case 'forgejo':
        return ForgejoReleasesAdapter();
      case 'playstore':
        return PlayStoreAdapter();
      case 'website':
        return WebsiteAdapter();
      default:
        return WebsiteAdapter();
    }
  }
}
