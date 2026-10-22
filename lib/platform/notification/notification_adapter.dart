library;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import '../../core/models/package.dart';
import '../../core/models/platform_ids.dart';
import '../../core/debug/debug_trace.dart';

/// 登录状态提醒使用独立通知渠道
///
/// 与「快递通知」分开，用户可单独静音登录提醒而不影响到件提醒——两者语义不同，
/// 混在同一渠道会让用户无法区分。
const String _keepAliveChannelId = 'keep_alive_channel';
const String _keepAliveChannelName = '登录状态提醒';

class NotificationAdapter {
  static final NotificationAdapter _instance = NotificationAdapter._();
  factory NotificationAdapter() => _instance;
  NotificationAdapter._();

  final _plugin = FlutterLocalNotificationsPlugin();

  static const int _arrivedBaseId = 10000;
  static const int _reminderBaseId = 20000;

  /// 保活相关通知独立号段，避开按 `Package.id` 派生的 10000/20000 段，
  /// 避免长登录失效提醒与包裹通知互相覆盖。
  static const int _keepAliveBaseId = 30000;

  /// 登录失效提醒的点击跳转 payload 前缀
  static const String keepAliveExpiredPrefix = 'keep_alive_expired:';

  /// 点击通知后待处理的路由
  ///
  /// 通知回调拿不到 `BuildContext`，App 还可能处于冷启动，
  /// 因此这里只做「投递」，由 `ui/app.dart` 在首帧后消费并导航。
  static final ValueNotifier<String?> pendingRoute = ValueNotifier<String?>(null);

  static String keepAliveExpiredPayload(String platform) =>
      '$keepAliveExpiredPrefix$platform';

  /// 从 payload 解析出失效平台；非保活 payload 返回 null
  static String? expiredPlatformFromPayload(String? payload) {
    if (payload == null || !payload.startsWith(keepAliveExpiredPrefix)) return null;
    return payload.substring(keepAliveExpiredPrefix.length);
  }

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    tz.initializeTimeZones();

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();

    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );
    _initialized = true;

    // 冷启动场景：App 是被用户点击通知拉起来的，补投一次路由
    try {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) {
        final payload = launch?.notificationResponse?.payload;
        if (expiredPlatformFromPayload(payload) != null) {
          pendingRoute.value = payload;
        }
      }
    } catch (e) {
      DebugTrace.separator('NOTIFICATION LAUNCH DETAILS FAILED: $e');
    }

    DebugTrace.separator('NOTIFICATION SERVICE INITIALIZED');
  }

  void _onNotificationResponse(NotificationResponse response) {
    DebugTrace.separator('NOTIFICATION CLICKED');
    final payload = response.payload;
    if (expiredPlatformFromPayload(payload) != null) {
      pendingRoute.value = payload;
    }
  }

  /// 通用通知：不绑定 [Package]，供登录失效等平台级提醒使用
  Future<void> notify({
    required int id,
    required String title,
    required String body,
    String? payload,
    String channelId = 'pickup_channel',
    String channelName = '快递通知',
    String channelDescription = '包裹到达提醒',
  }) async {
    await _showNotification(
      id: id,
      title: title,
      body: body,
      payload: payload,
      channelId: channelId,
      channelName: channelName,
      channelDescription: channelDescription,
    );
  }

  /// 登录态失效提醒
  ///
  /// 通知 id 按平台固定槽位，同一平台重复提醒是**替换**而不是堆叠。
  Future<void> showKeepAliveExpiredNotification({
    required String platform,
    required String displayName,
  }) async {
    final slot = kPlatformIds.indexOf(platform);
    final id = _keepAliveBaseId + (slot >= 0 ? slot + 1 : 99);

    DebugTrace.separator('SHOW KEEPALIVE EXPIRED NOTIFICATION');

    await notify(
      id: id,
      title: '$displayName 登录态已失效',
      body: '点击前往「设置」重新登录，以继续自动同步包裹',
      payload: keepAliveExpiredPayload(platform),
      channelId: _keepAliveChannelId,
      channelName: _keepAliveChannelName,
      channelDescription: '平台登录状态提醒',
    );
  }

  Future<void> showArrivedNotification(Package package) async {
    DebugTrace.separator('SHOW ARRIVED NOTIFICATION');
    print('package: ${package.courier.shortName} ${package.pickupCode}');

    final title = _buildArrivedTitle(package);
    final body = _buildArrivedBody(package);
    final notificationId = _arrivedBaseId + package.id.hashCode.abs() % 10000;

    await _showNotification(
      id: notificationId,
      title: title,
      body: body,
      payload: 'arrived:${package.id}',
    );
  }

  String _buildArrivedTitle(Package package) {
    // 优先显示商品名，如果没有则显示「快递到了！」
    if (package.goodsName != null && package.goodsName!.trim().isNotEmpty) {
      final goodsName = package.goodsName!.trim();
      // 商品名过长时截断（通知标题最多显示约 40 个字符）
      return goodsName.length > 18 ? '${goodsName.substring(0, 18)}...' : goodsName;
    }
    return '快递到了！';
  }

  String _buildArrivedBody(Package package) {
    final courier = package.courier.shortName;
    final parts = <String>[];

    // 显示快递公司
    parts.add(courier);

    // 显示取件码
    if (package.pickupCode.isNotEmpty) {
      parts.add('取件码：${package.pickupCode}');
    }

    // 显示驿站名（如果有）
    if (package.stationName != null && package.stationName!.trim().isNotEmpty) {
      final stationName = package.stationName!.trim();
      // 驿站名过长时截断
      final displayStation = stationName.length > 12 ? '${stationName.substring(0, 12)}...' : stationName;
      parts.add(displayStation);
    }

    // 如果没有取件码，显示地址信息
    if (package.pickupCode.isEmpty && package.location.isNotEmpty) {
      parts.add('已到 ${package.location}');
    }

    return parts.join(' · ');
  }

  Future<void> scheduleReminderNotification(Package package) async {
    DebugTrace.separator('SCHEDULE REMINDER NOTIFICATION');
    print('package: ${package.courier.shortName}');

    final title = '快递还在等你';
    final body = '${package.courier.shortName} 已等待超过 24 小时';
    final notificationId = _reminderBaseId + package.id.hashCode.abs() % 10000;

    await _scheduleNotification(
      id: notificationId,
      title: title,
      body: body,
      payload: 'reminder:${package.id}',
      delay: const Duration(hours: 24),
    );
  }

  Future<void> cancelNotification(String packageId) async {
    DebugTrace.separator('CANCEL NOTIFICATION');
    print('packageId: $packageId');

    final arrivedId = _arrivedBaseId + packageId.hashCode.abs() % 10000;
    final reminderId = _reminderBaseId + packageId.hashCode.abs() % 10000;

    try {
      await _plugin.cancel(arrivedId);
      await _plugin.cancel(reminderId);
    } catch (_) {}
  }

  Future<void> _showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
    String channelId = 'pickup_channel',
    String channelName = '快递通知',
    String channelDescription = '包裹到达提醒',
  }) async {
    final android = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );
    const ios = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    final details = NotificationDetails(android: android, iOS: ios);

    await _plugin.show(id, title, body, details, payload: payload);
  }

  Future<void> _scheduleNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
    required Duration delay,
  }) async {
    const android = AndroidNotificationDetails(
      'pickup_channel',
      '快递通知',
      channelDescription: '包裹到达提醒',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );
    const ios = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const details = NotificationDetails(android: android, iOS: ios);

    final scheduledDate = tz.TZDateTime.now(tz.local).add(delay);

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      scheduledDate,
      details,
      payload: payload,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }
}