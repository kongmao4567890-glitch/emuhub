import 'dart:async';

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

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const EmuHubApp(),
    ),
  );

  // 通知与后台任务都不是首帧渲染的前置条件。放到 runApp 之后初始化，
  // 避免插件异常或较慢的平台调用造成白屏、闪退或启动时间过长。
  unawaited(_initializeBackgroundServices(settings));
}

Future<void> _initializeBackgroundServices(AppSettings settings) async {
  try {
    if (settings.notificationEnabled) {
      await NotificationService().initialize();
    }
    await BackgroundTask.initializeWorkmanager();
    await BackgroundTask.registerPeriodicTask(
      frequency: settings.checkIntervalDuration,
      wifiOnly: settings.wifiOnly,
    );
  } catch (_) {
    // 后台能力不可用时不影响前台浏览与手动检查。
  }
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
