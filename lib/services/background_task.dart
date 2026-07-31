import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../data/database/database.dart';
import '../data/models/emulator.dart';
import '../data/models/emulators_config.dart';
import '../data/repositories/settings_repository.dart';
import 'notification_service.dart';
import 'update/update_service.dart';

/// 后台更新检查任务。
///
/// 基于 [workmanager](https://pub.dev/packages/workmanager) 注册周期性后台任务，
/// 定期调用 [UpdateService.checkAll] 检查模拟器的版本更新，并在发现新版本时
/// 通过 [NotificationService] 发送通知。
///
/// 后台任务会读取用户设置：检查范围（全部/仅收藏）、通知开关、免打扰时段；
/// 检查间隔与“仅 Wi-Fi”约束在 [registerPeriodicTask] 注册时生效。
///
/// 使用流程：
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await BackgroundTask.initializeWorkmanager();
///   await BackgroundTask.registerPeriodicTask(); // 默认每 4 小时
///   runApp(...);
/// }
/// ```
class BackgroundTask {
  BackgroundTask._();

  /// 后台任务唯一名称 / 任务名（同时也是 uniqueName 与 taskName）。
  static const String taskName = 'emuhubUpdateCheck';

  /// 本地数据库文件名。
  ///
  /// 注意：必须与主应用创建 [AppDatabase] 时使用的文件名保持一致，
  /// 否则后台任务与前台将访问不同的数据库。
  static const String databaseName = 'emuhub.db';

  /// 初始化 workmanager，注册 [callbackDispatcher]。
  ///
  /// 应在 `main()` 中 `WidgetsFlutterBinding.ensureInitialized()` 之后调用。
  static Future<void> initializeWorkmanager({
    bool isInDebugMode = false,
  }) async {
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: isInDebugMode,
    );
  }

  /// 注册周期性后台任务，默认每 4 小时执行一次。
  ///
  /// [frequency] 最小为 15 分钟，低于该值会被系统自动调整为 15 分钟。
  /// [wifiOnly] 为 true 时任务仅在非计量网络（Wi-Fi）下执行。
  /// 已存在同名任务时使用 [ExistingPeriodicWorkPolicy.update] 更新调度参数。
  static Future<void> registerPeriodicTask({
    Duration frequency = const Duration(hours: 4),
    bool wifiOnly = false,
  }) async {
    await Workmanager().registerPeriodicTask(
      taskName,
      taskName,
      frequency: frequency,
      constraints: Constraints(
        networkType:
            wifiOnly ? NetworkType.unmetered : NetworkType.connected,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }

  /// 取消已注册的周期性后台任务。
  static Future<void> cancelTask() async {
    await Workmanager().cancelByUniqueName(taskName);
  }
}

/// workmanager 回调入口。
///
/// 运行在后台 isolate 中，因此需要先调用
/// [BackgroundIsolateBinaryMessenger.ensureInitialized] 初始化二进制信使，
/// 才能访问 `rootBundle` 与平台通道（如 path_provider、shared_preferences）。
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != BackgroundTask.taskName) {
      return true;
    }

    AppDatabase? db;
    try {
      // 后台 isolate 中初始化 binary messenger，以便访问 rootBundle / 平台通道
      final token = RootIsolateToken.instance;
      if (token != null) {
        BackgroundIsolateBinaryMessenger.ensureInitialized(token);
      }

      // 读取用户设置（通知开关 / 免打扰时段 / 检查范围）
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsRepository(prefs).getSettings();

      // 加载模拟器列表
      final emulators = await _loadEmulators();
      if (emulators.isEmpty) {
        // 资源加载失败属于异常，返回 false 让 workmanager 按策略重试
        return false;
      }

      // 打开数据库
      db = await _openDatabase();

      // 按检查范围过滤：仅收藏时只检查开启了通知的收藏项
      var targets = emulators;
      if (settings.checkScope == CheckScope.favoritesOnly) {
        final favorites = await db.favoritesDao.getAllFavorites();
        final notifiableIds = favorites
            .where((f) => f.notify)
            .map((f) => f.emulatorId)
            .toSet();
        targets =
            emulators.where((e) => notifiableIds.contains(e.id)).toList();
      }

      // 无检查目标时直接成功结束
      if (targets.isEmpty) {
        return true;
      }

      // 记录更新前的版本号，用于通知中的“旧版本”展示
      final cachedBefore = await db.cachedVersionsDao.getAllCachedVersions();
      final oldVersions = <String, String>{
        for (final c in cachedBefore) c.emulatorId: c.currentVersion,
      };

      // 执行更新检查
      final updateService = UpdateService(dao: db.cachedVersionsDao);
      final result = await updateService.checkAll(targets);

      // 有更新且通知开启、不在免打扰时段内，则逐个发送通知
      if (result.hasUpdates &&
          settings.notificationEnabled &&
          !_isInQuietHours(
            settings.quietHoursStart,
            settings.quietHoursEnd,
            DateTime.now(),
          )) {
        final notif = NotificationService();
        await notif.initialize();
        for (final info in result.updated) {
          final name = _emulatorName(emulators, info.emulatorId);
          final old = oldVersions[info.emulatorId] ?? '未知版本';
          await notif.showUpdateNotification(name, old, info.version);
        }
      }

      return true;
    } catch (_) {
      // 任意异常都返回 false，让 workmanager 可按策略重试
      return false;
    } finally {
      await db?.close();
    }
  });
}

/// 从 `assets/emulators.json` 加载全部模拟器列表。
///
/// 加载失败时返回空列表，调用方据此判定本次任务失败并重试。
Future<List<Emulator>> _loadEmulators() async {
  try {
    final raw = await rootBundle.loadString('assets/emulators.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final config = EmulatorsConfig.fromJson(json);
    return config.consoles.expand((console) => console.emulators).toList();
  } catch (_) {
    return const <Emulator>[];
  }
}

/// 打开本地数据库。
///
/// 使用 [NativeDatabase] 直接打开文件（后台 isolate 中不宜再派生 isolate）。
Future<AppDatabase> _openDatabase() async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/${BackgroundTask.databaseName}');
  return AppDatabase(NativeDatabase(file));
}

/// 判断 [now] 是否处于免打扰时段内（支持跨午夜时段，如 22:00–08:00）。
bool _isInQuietHours(String start, String end, DateTime now) {
  final startMinutes = _parseHourMinute(start);
  final endMinutes = _parseHourMinute(end);
  if (startMinutes == null || endMinutes == null) return false;
  if (startMinutes == endMinutes) return false;

  final current = now.hour * 60 + now.minute;
  if (startMinutes < endMinutes) {
    // 不跨午夜：如 12:00–14:00
    return current >= startMinutes && current < endMinutes;
  }
  // 跨午夜：如 22:00–08:00
  return current >= startMinutes || current < endMinutes;
}

/// 将 "HH:mm" 格式的时间解析为从 0 点起的分钟数，格式非法时返回 null。
int? _parseHourMinute(String value) {
  final parts = value.split(':');
  if (parts.length != 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return hour * 60 + minute;
}

/// 根据 id 查找模拟器名称，未找到时返回 id 本身。
String _emulatorName(List<Emulator> emulators, String id) {
  for (final e in emulators) {
    if (e.id == id) return e.name;
  }
  return id;
}
