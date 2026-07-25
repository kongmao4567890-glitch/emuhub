import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 本地通知服务（单例）。
///
/// 封装 [flutter_local_notifications](https://pub.dev/packages/flutter_local_notifications)，
/// 负责初始化通知通道并发送“模拟器版本更新”通知。
///
/// 通道信息：
/// - id：`emuhub_updates`
/// - name：`模拟器更新`
/// - description：`模拟器版本更新通知`
class NotificationService {
  NotificationService._();
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;

  static const String channelId = 'emuhub_updates';
  static const String channelName = '模拟器更新';
  static const String channelDescription = '模拟器版本更新通知';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  int _nextId = 0;

  /// 初始化插件并创建 Android 通知通道。
  ///
  /// 重复调用是安全的，内部仅执行一次。
  Future<void> initialize() async {
    if (_initialized) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );

    await _plugin.initialize(initSettings);

    // 创建通知通道（Android 8.0+）
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
      const AndroidNotificationChannel(
        channelId,
        channelName,
        description: channelDescription,
        importance: Importance.high,
      ),
    );

    _initialized = true;
  }

  /// 发送一条“有新版本”通知。
  ///
  /// [emulatorName] 模拟器名称；[oldVersion] 旧版本号；[newVersion] 新版本号。
  Future<void> showUpdateNotification(
    String emulatorName,
    String oldVersion,
    String newVersion,
  ) async {
    await initialize();

    final id = _nextId++;
    const androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.show(
      id,
      '$emulatorName 有新版本',
      '已更新：$oldVersion → $newVersion',
      details,
    );
  }

  /// 取消全部已发送的通知。
  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }
}
