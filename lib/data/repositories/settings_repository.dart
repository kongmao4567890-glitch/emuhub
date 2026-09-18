import 'package:shared_preferences/shared_preferences.dart';

/// 更新检查间隔。
///
/// 用于后台周期性任务与前台手动检查的默认间隔。
enum CheckInterval { twoHours, fourHours, sixHours, twelveHours }

/// 更新检查范围。
///
/// - [all]：检查全部模拟器。
/// - [favoritesOnly]：仅检查已收藏的模拟器。
enum CheckScope { all, favoritesOnly }

/// 应用用户设置。
///
/// 不可变值对象，通过 [copyWith] 产生新实例。
/// 默认值与产品需求一致：每 4 小时检查、检查全部、开启通知、
/// 22:00–08:00 免打扰、不限 Wi-Fi。
class AppSettings {
  final CheckInterval checkInterval;
  final CheckScope checkScope;
  final bool notificationEnabled;
  final String quietHoursStart; // 形如 "22:00"
  final String quietHoursEnd; // 形如 "08:00"
  final bool wifiOnly;

  const AppSettings({
    this.checkInterval = CheckInterval.fourHours,
    this.checkScope = CheckScope.all,
    this.notificationEnabled = true,
    this.quietHoursStart = '22:00',
    this.quietHoursEnd = '08:00',
    this.wifiOnly = false,
  });

  /// 复制并覆盖部分字段，未提供的字段保持原值。
  AppSettings copyWith({
    CheckInterval? checkInterval,
    CheckScope? checkScope,
    bool? notificationEnabled,
    String? quietHoursStart,
    String? quietHoursEnd,
    bool? wifiOnly,
  }) {
    return AppSettings(
      checkInterval: checkInterval ?? this.checkInterval,
      checkScope: checkScope ?? this.checkScope,
      notificationEnabled: notificationEnabled ?? this.notificationEnabled,
      quietHoursStart: quietHoursStart ?? this.quietHoursStart,
      quietHoursEnd: quietHoursEnd ?? this.quietHoursEnd,
      wifiOnly: wifiOnly ?? this.wifiOnly,
    );
  }

  /// 当前检查间隔对应的小时数。
  int get checkIntervalHours {
    switch (checkInterval) {
      case CheckInterval.twoHours:
        return 2;
      case CheckInterval.fourHours:
        return 4;
      case CheckInterval.sixHours:
        return 6;
      case CheckInterval.twelveHours:
        return 12;
    }
  }

  /// 当前检查间隔对应的 [Duration]。
  Duration get checkIntervalDuration =>
      Duration(hours: checkIntervalHours);
}

/// SharedPreferences 存储键常量。
///
/// 集中管理以便后续迁移或统一清理。
class _StorageKeys {
  static const String checkInterval = 'settings_check_interval';
  static const String checkScope = 'settings_check_scope';
  static const String notificationEnabled = 'settings_notification_enabled';
  static const String quietHoursStart = 'settings_quiet_hours_start';
  static const String quietHoursEnd = 'settings_quiet_hours_end';
  static const String wifiOnly = 'settings_wifi_only';
}

/// 用户设置仓库。
///
/// 基于 [SharedPreferences] 进行持久化。枚举以 `index` 整数存储，
/// 布尔与字符串直接存储。读取时若键不存在或值非法，回退到 [AppSettings]
/// 的默认值，保证向前兼容。
class SettingsRepository {
  final SharedPreferences _prefs;

  SettingsRepository(this._prefs);

  /// 读取全部设置，合并默认值后返回 [AppSettings]。
  AppSettings getSettings() {
    return AppSettings(
      checkInterval: _readCheckInterval(),
      checkScope: _readCheckScope(),
      notificationEnabled:
          _prefs.getBool(_StorageKeys.notificationEnabled) ?? true,
      quietHoursStart:
          _prefs.getString(_StorageKeys.quietHoursStart) ?? '22:00',
      quietHoursEnd: _prefs.getString(_StorageKeys.quietHoursEnd) ?? '08:00',
      wifiOnly: _prefs.getBool(_StorageKeys.wifiOnly) ?? false,
    );
  }

  /// 将 [settings] 的全部字段写入 SharedPreferences。
  ///
  /// 各字段并行写入，任一失败不影响其它字段（但会抛出对应异常）。
  Future<void> saveSettings(AppSettings settings) async {
    await Future.wait([
      _prefs.setInt(_StorageKeys.checkInterval, settings.checkInterval.index),
      _prefs.setInt(_StorageKeys.checkScope, settings.checkScope.index),
      _prefs.setBool(
        _StorageKeys.notificationEnabled,
        settings.notificationEnabled,
      ),
      _prefs.setString(_StorageKeys.quietHoursStart, settings.quietHoursStart),
      _prefs.setString(_StorageKeys.quietHoursEnd, settings.quietHoursEnd),
      _prefs.setBool(_StorageKeys.wifiOnly, settings.wifiOnly),
    ]);
  }

  CheckInterval _readCheckInterval() {
    final index = _prefs.getInt(_StorageKeys.checkInterval);
    if (index == null || index < 0 || index >= CheckInterval.values.length) {
      return CheckInterval.fourHours;
    }
    return CheckInterval.values[index];
  }

  CheckScope _readCheckScope() {
    final index = _prefs.getInt(_StorageKeys.checkScope);
    if (index == null || index < 0 || index >= CheckScope.values.length) {
      return CheckScope.all;
    }
    return CheckScope.values[index];
  }
}
