import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/constants/app_constants.dart';
import 'data/database/database.dart';
import 'data/models/emulators_config.dart';
import 'data/repositories/settings_repository.dart';
import 'services/background_task.dart';
import 'services/notification_service.dart';
import 'services/update/update_service.dart';

/// 应用本地数据库单例。
///
/// 使用 [LazyDatabase] 在首次查询时才解析数据库文件路径并打开连接，
/// 因此本 [Provider] 本身是同步的，而文件路径（依赖 [path_provider]）
/// 的异步解析被推迟到实际访问时进行。应用退出时通过 [ref.onDispose]
/// 关闭连接。
final Provider<AppDatabase> appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase(
    LazyDatabase(() async {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/${AppConstants.databaseName}');
      return NativeDatabase.createInBackground(file);
    }),
  );
  ref.onDispose(db.close);
  return db;
});

/// SharedPreferences 实例。
///
/// 同步 Provider，必须在 `main()` 中通过 `ProviderScope.overrides`
/// 注入已加载完成的实例：
/// ```dart
/// final prefs = await SharedPreferences.getInstance();
/// ProviderScope(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)])
/// ```
/// 未 override 时访问会抛出 [UnimplementedError]。
final Provider<SharedPreferences> sharedPreferencesProvider =
    Provider<SharedPreferences>((ref) {
  throw UnimplementedError(
    'sharedPreferencesProvider 必须在 main() 中 override 注入',
  );
});

/// 用户设置仓库。
///
/// 依赖 [sharedPreferencesProvider]（同步，已在 main() 中注入实例）。
final Provider<SettingsRepository> settingsRepositoryProvider =
    Provider<SettingsRepository>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return SettingsRepository(prefs);
});

/// [AppSettings] 的状态管理器。
///
/// 初值从 [SettingsRepository] 读取已持久化的设置；
/// [updateSettings] 在更新内存状态的同时写回 SharedPreferences。
class AppSettingsNotifier extends StateNotifier<AppSettings> {
  AppSettingsNotifier(this._repository)
      : super(_repository.getSettings());

  final SettingsRepository _repository;

  /// 用新的设置覆盖当前状态并持久化。
  ///
  /// 持久化后按新设置重新调度后台周期任务（检查间隔 / 仅 Wi-Fi 约束
  /// 可能已变化）；调度失败不影响设置保存结果。
  Future<void> updateSettings(AppSettings settings) async {
    final notificationsJustEnabled =
        !state.notificationEnabled && settings.notificationEnabled;
    final notificationsJustDisabled =
        state.notificationEnabled && !settings.notificationEnabled;
    await _repository.saveSettings(settings);
    state = settings;
    try {
      if (notificationsJustEnabled) {
        await NotificationService().initialize();
      } else if (notificationsJustDisabled) {
        await NotificationService().cancelAll();
      }
      await BackgroundTask.registerPeriodicTask(
        frequency: settings.checkIntervalDuration,
        wifiOnly: settings.wifiOnly,
      );
    } catch (_) {
      // workmanager 未初始化或平台不支持时忽略
    }
  }
}

/// 当前应用设置。
///
/// 依赖 [settingsRepositoryProvider]，同样需要在 SharedPreferences 就绪后访问。
final StateNotifierProvider<AppSettingsNotifier, AppSettings> appSettingsProvider =
    StateNotifierProvider<AppSettingsNotifier, AppSettings>((ref) {
  final repository = ref.watch(settingsRepositoryProvider);
  return AppSettingsNotifier(repository);
});

/// 模拟器配置（从 `assets/emulators.json` 加载）。
///
/// 加载或解析失败时为 [AsyncError]，UI 层可据此展示错误态并支持重试。
final FutureProvider<EmulatorsConfig> emulatorsConfigProvider =
    FutureProvider<EmulatorsConfig>((ref) async {
  final raw = await rootBundle.loadString('assets/emulators.json');
  final json = jsonDecode(raw) as Map<String, dynamic>;
  return EmulatorsConfig.fromJson(json);
});

/// 更新检查编排服务。
///
/// 绑定 [AppDatabase.cachedVersionsDao]，并发上限取自 [AppConstants]。
final Provider<UpdateService> updateServiceProvider =
    Provider<UpdateService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return UpdateService(
    dao: db.cachedVersionsDao,
    maxConcurrency: AppConstants.maxConcurrentChecks,
    requestDelay: AppConstants.updateBatchDelay,
  );
});

/// 本地通知服务（单例）。
///
/// [NotificationService] 内部为工厂单例，[NotificationService.initialize]
/// 可安全重复调用。建议在 `main()` 中尽早调用一次 `initialize()`，
/// 此后通过本 provider 取同一实例使用。
final Provider<NotificationService> notificationServiceProvider =
    Provider<NotificationService>((ref) {
  return NotificationService();
});
