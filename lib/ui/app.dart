import 'package:flutter/material.dart';

import '../platform/notification/notification_adapter.dart';
import 'screens/home/home_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'theme/app_theme.dart';

/// 全局 Navigator：通知点击时回调里没有 `BuildContext`，需要它来发起导航
final appNavigatorKey = GlobalKey<NavigatorState>();

class PickupApp extends StatefulWidget {
  const PickupApp({super.key});

  @override
  State<PickupApp> createState() => _PickupAppState();
}

class _PickupAppState extends State<PickupApp> {
  @override
  void initState() {
    super.initState();
    NotificationAdapter.pendingRoute.addListener(_consumePendingRoute);
    // 冷启动时 payload 可能已在 initialize() 阶段投递，首帧后补处理一次
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumePendingRoute());
  }

  @override
  void dispose() {
    NotificationAdapter.pendingRoute.removeListener(_consumePendingRoute);
    super.dispose();
  }

  void _consumePendingRoute() {
    final payload = NotificationAdapter.pendingRoute.value;
    if (payload == null) return;

    // 先清空再导航，避免同一 payload 被重复消费
    NotificationAdapter.pendingRoute.value = null;

    if (NotificationAdapter.expiredPlatformFromPayload(payload) != null) {
      appNavigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '待取件',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      navigatorKey: appNavigatorKey,
      home: const HomeScreen(),
    );
  }
}
