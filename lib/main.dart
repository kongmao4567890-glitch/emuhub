import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'data/repositories/settings_repository.dart';
import 'providers.dart';
import 'services/background_task.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 提前同步加载 SharedPreferences，并通过 override 注入 ProviderScope，
  // 使 settingsRepositoryProvider / appSettingsProvider 可以同步访问，
  // 避免异步加载期间的 requireValue 竞态崩溃。
  final prefs = await SharedPreferences.getInstance();
  final settings = SettingsRepository(prefs).getSettings();

  // 初始化本地通知服务（含 Android 13+ 通知运行时权限请求）。
  await NotificationService().initialize();

  // 初始化 workmanager 并按用户设置注册周期性后台更新检查。
  // 失败（如非 Android 平台）不应阻断应用启动。
  try {
    await BackgroundTask.initializeWorkmanager();
    await BackgroundTask.registerPeriodicTask(
      frequency: settings.checkIntervalDuration,
      wifiOnly: settings.wifiOnly,
    );
  } catch (_) {
    // 后台任务注册失败不影响前台功能
  }

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const EmuHubApp(),
    ),
  );
}

class EmuHubApp extends ConsumerWidget {
  const EmuHubApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'EmuHub',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      routerConfig: router,
    );
  }
}
