import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:workmanager/workmanager.dart';
import 'platform/storage/hive_adapters.dart';
import 'core/debug/debug_trace.dart';
import 'platform/storage/hive_package.dart';
import 'platform/storage/platform_auth_store.dart';
import 'platform/storage/keep_alive_store.dart';
import 'platform/sync/sync_history_manager.dart';
import 'platform/notification/notification_adapter.dart';
import 'platform/keep_alive/keep_alive_worker.dart';
import 'ui/app.dart';

const String kPackagesBox = 'packages';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  DebugTrace.separator('MAIN: Hive.initFlutter');
  await initializeDateFormatting('zh_CN', null);
  await Hive.initFlutter();
  print('Hive.initFlutter done');

  Hive
    ..registerAdapter(PackageStatusAdapter())
    ..registerAdapter(UrgencyLevelAdapter())
    ..registerAdapter(CourierTypeAdapter())
    ..registerAdapter(HivePackageAdapter());
  print('Adapters registered (4)');

  DebugTrace.separator('MAIN: openBox');
  final box = await Hive.openBox<HivePackage>(kPackagesBox);
  print('box.name: ${box.name}');
  print('box.isOpen: ${box.isOpen}');
  print('box.length: ${box.length}');

  // 预打开平台凭据存储，确保重启后已绑定的平台账号立即可读
  await PlatformAuthStore.initialize();
  print('PlatformAuthStore initialized');

  // 保活调度状态（含「下次保活时间」闸门）：落盘后冷启动不再重发心跳
  await KeepAliveStore.initialize();
  await KeepAliveStore().ensureSchemaVersion();
  print('KeepAliveStore initialized');

  // 预打开同步历史：保活靠「最近同步时间」跳过刚同步过的平台
  await SyncHistoryManager.initialize();
  print('SyncHistoryManager initialized');

  DebugTrace.separator('MAIN: NotificationAdapter');
  await NotificationAdapter().initialize();
  print('NotificationAdapter initialized');

  // 注册后台保活任务（WorkManager）：App 进程被杀后仍能定时续期淘宝/京东登录态
  await Workmanager().initialize(callbackDispatcher);
  await Workmanager().registerPeriodicTask(
    'keep_alive_periodic',
    'keepAliveTask',
    frequency: const Duration(hours: 6),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );
  print('WorkManager keep-alive task registered');

  DebugTrace.separator('MAIN: runApp');
  runApp(const ProviderScope(child: PickupApp()));
}