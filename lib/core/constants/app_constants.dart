/// 应用全局常量。
///
/// 集中管理应用名称、版本、仓库地址、数据库名等不变配置，
/// 便于维护与统一引用。
class AppConstants {
  AppConstants._();

  /// 应用名称。
  static const String appName = 'EmuHub';

  /// 应用版本号（语义化版本）。
  /// GitHub Actions 会用发布构建号注入该值，使关于页与 Release 标签一致。
  static const String appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.0.34',
  );

  /// App 自身更新检查所使用的 GitHub 仓库地址。
  ///
  /// 由 App 更新检查逻辑读取最新 Release 附带的轻量清单，
  /// 避免匿名 GitHub API 配额导致 403。
  static const String githubRepo =
      'https://github.com/kongmao4567890-glitch/emuhub';

  /// 本地数据库文件名。
  ///
  /// 必须与后台任务中使用的文件名保持一致。
  static const String databaseName = 'emuhub.db';

  /// 默认更新检查间隔。
  ///
  /// 当用户未自定义检查间隔时使用，亦作为后台任务的默认频率。
  static const Duration defaultCheckInterval = Duration(hours: 4);

  /// 更新检查的最大并发数。
  ///
  /// 10 路并发可显著缩短全量检查时间，同时仍低于常见数据源的限流阈值。
  static const int maxConcurrentChecks = 10;

  /// 相邻更新检查批次之间的节流间隔。
  ///
  /// 保留短暂间隔以避免突发请求，但避免全量检查累计数十秒的无效等待。
  static const Duration updateBatchDelay = Duration(milliseconds: 150);
}
