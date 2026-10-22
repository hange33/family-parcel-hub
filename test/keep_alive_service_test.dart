import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:pickup_app/platform/keep_alive/keep_alive_service.dart';
import 'package:pickup_app/platform/keep_alive/platform_heartbeat.dart';
import 'package:pickup_app/platform/storage/keep_alive_store.dart';
import 'package:pickup_app/platform/storage/platform_auth_store.dart';

/// 只实现保活需要的读接口，避免依赖 Hive 与真实凭据
class _FakeAuthStore extends PlatformAuthStore {
  _FakeAuthStore({Set<String>? bound}) : _bound = bound ?? {'taobao'};

  final Set<String> _bound;
  final Set<String> expired = {};
  Duration cookieAge = const Duration(days: 2);

  @override
  bool isBound(String platform) => _bound.contains(platform);

  @override
  String? getCookies(String platform) => _bound.contains(platform) ? 'k=v' : null;

  @override
  DateTime? getBoundTime(String platform) =>
      _bound.contains(platform) ? DateTime.now().subtract(cookieAge) : null;

  @override
  bool isExpired(String platform) => expired.contains(platform);

  @override
  Future<void> setExpired(String platform, bool value) async {
    if (value) {
      expired.add(platform);
    } else {
      expired.remove(platform);
    }
  }
}

class _FakeHeartbeat implements PlatformHeartbeat {
  _FakeHeartbeat(this.platformId);

  @override
  final String platformId;

  /// 返回 null 时按成功处理
  HeartbeatResult Function()? responder;
  int calls = 0;

  @override
  Future<HeartbeatResult> performHeartbeat(String cookies) async {
    calls++;
    return responder?.call() ?? HeartbeatResult.success();
  }
}

void main() {
  late Directory tempDir;
  late _FakeAuthStore auth;
  late KeepAliveStore store;
  late _FakeHeartbeat taobaoHb;
  late KeepAliveService service;

  KeepAliveService buildService({
    DateTime? Function(String platform)? lastSync,
    Map<String, PlatformHeartbeat>? heartbeats,
    Future<void> Function(List<String> platforms)? notifyExpired,
  }) {
    final s = KeepAliveService(
      authStore: auth,
      store: store,
      heartbeats: heartbeats ?? {'taobao': taobaoHb},
      lastSyncTimeResolver: lastSync,
      interPlatformDelay: Duration.zero,
      // 默认不发通知：真实通知走平台通道，单测里注入记录用的假实现
      notifyExpired: notifyExpired ?? (_) async {},
    );
    return s;
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('keep_alive_service_test');
    Hive.init(tempDir.path);
    await KeepAliveStore.initialize();

    auth = _FakeAuthStore();
    store = KeepAliveStore();
    await store.loadIntoCache();
    taobaoHb = _FakeHeartbeat('taobao');
    service = buildService();
  });

  tearDown(() async {
    service.dispose();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('冷启动不再重发心跳（本次修复的核心回归点）', () {
    test('闸门未到时不发心跳', () async {
      await store.setNext('taobao', DateTime.now().add(const Duration(hours: 6)));

      await service.start();

      expect(taobaoHb.calls, 0);
    });

    test('首次启动无闸门时发一次，并落盘下次保活时间', () async {
      await service.start();

      expect(taobaoHb.calls, 1);
      expect(store.nextAt('taobao'), isNotNull);
    });

    test('模拟重启：新进程实例读同一份存储，不再重发', () async {
      await service.start();
      expect(taobaoHb.calls, 1);

      // 新服务实例 + 新的 KeepAliveStore（不共享内存缓存）= 重启后的 App
      final restarted = KeepAliveService(
        authStore: auth,
        store: KeepAliveStore(),
        heartbeats: {'taobao': taobaoHb},
        interPlatformDelay: Duration.zero,
        notifyExpired: (_) async {},
      );
      addTearDown(restarted.dispose);

      await restarted.start();

      expect(taobaoHb.calls, 1, reason: '闸门落盘后冷启动不应重发心跳');
    });

    test('手动保活绕过闸门，立即真实执行一轮', () async {
      await store.setNext('taobao', DateTime.now().add(const Duration(hours: 6)));

      await service.performManualKeepAlive();

      expect(taobaoHb.calls, 1);
    });

    test('并发 start 只跑一轮，不重复创建定时器', () async {
      await Future.wait([service.start(), service.start()]);

      expect(taobaoHb.calls, 1);
    });

    test('缺少心跳实现的平台被跳过，且不为它排期', () async {
      final jdHb = _FakeHeartbeat('jd');
      auth = _FakeAuthStore(bound: {'taobao', 'jd'});
      service = buildService(heartbeats: {'jd': jdHb});

      await service.performManualKeepAlive();

      expect(jdHb.calls, 1);
      expect(taobaoHb.calls, 0);
      expect(store.nextAt('taobao'), isNull, reason: '没有实现就不该被静默排期');
      expect(store.nextAt('jd'), isNotNull);
    });
  });

  group('跳过规则', () {
    test('用户 1 小时前同步过 → 后台检查跳过', () async {
      final s = buildService(
        lastSync: (_) => DateTime.now().subtract(const Duration(hours: 1)),
      );
      addTearDown(s.dispose);

      await s.start();

      expect(taobaoHb.calls, 0);
    });

    test('用户 7 小时前同步过 → 不再跳过', () async {
      final s = buildService(
        lastSync: (_) => DateTime.now().subtract(const Duration(hours: 7)),
      );
      addTearDown(s.dispose);

      await s.start();

      expect(taobaoHb.calls, 1);
    });

    test('未绑定的平台不下发心跳', () async {
      auth = _FakeAuthStore(bound: {});
      service = buildService();

      await service.performManualKeepAlive();

      expect(taobaoHb.calls, 0);
    });

    test('单平台关闭后跳过该平台', () async {
      await service.setPlatformEnabled('taobao', false);

      await service.performManualKeepAlive();

      expect(taobaoHb.calls, 0);
    });

    test('总开关关闭后不启动', () async {
      await service.setEnabled(false);

      await service.start();

      expect(taobaoHb.calls, 0);
    });
  });

  group('失败处理', () {
    test('非登录类失败累计 3 次才判定失效', () async {
      taobaoHb.responder = () => HeartbeatResult.failure('网络错误');

      await service.performManualKeepAlive();
      expect(auth.isExpired('taobao'), isFalse);
      expect(store.failureCount('taobao'), 1);

      await service.performManualKeepAlive();
      expect(auth.isExpired('taobao'), isFalse);
      expect(store.failureCount('taobao'), 2);

      await service.performManualKeepAlive();
      expect(auth.isExpired('taobao'), isTrue);
      expect(store.failureCount('taobao'), 3);
    });

    test('明确的登录失效一次即判定', () async {
      taobaoHb.responder =
          () => HeartbeatResult.failure('登录态已失效', isAuthFailure: true);

      await service.performManualKeepAlive();

      expect(auth.isExpired('taobao'), isTrue);
      expect(store.failureCount('taobao'), 3);
    });

    test('心跳抛异常不会冒泡，按失败计数', () async {
      taobaoHb.responder = () => throw StateError('boom');

      await service.performManualKeepAlive();

      expect(store.failureCount('taobao'), 1);
    });

    test('成功时失败计数归零并清除失效标记', () async {
      await store.setFailureCount('taobao', 2);
      auth.expired.add('taobao');

      await service.performManualKeepAlive();

      expect(store.failureCount('taobao'), 0);
      expect(auth.isExpired('taobao'), isFalse);
    });
  });

  group('跳过的语义', () {
    test('skipped 不计失败、不清除已有失效标记', () async {
      auth.expired.add('taobao');
      taobaoHb.responder = () => HeartbeatResult.skipped('WebView 正忙');

      await service.performManualKeepAlive();

      expect(store.failureCount('taobao'), 0, reason: '跳过既不算成功也不算失败');
      expect(auth.isExpired('taobao'), isTrue, reason: '跳过不得清掉失效标记');
      expect(store.history.records.first.skipped, isTrue);
    });

    test('skipped 不覆盖最近保活时间', () async {
      taobaoHb.responder = () => HeartbeatResult.skipped('WebView 正忙');

      await service.performManualKeepAlive();

      expect(store.lastAt('taobao'), isNull);
    });
  });

  group('失效提醒联动', () {
    test('判定失效后把平台交给提醒回调', () async {
      final notified = <List<String>>[];
      service = buildService(notifyExpired: (platforms) async => notified.add(platforms));
      taobaoHb.responder =
          () => HeartbeatResult.failure('登录态已失效', isAuthFailure: true);

      await service.performManualKeepAlive();

      expect(notified, hasLength(1));
      expect(notified.single, contains('taobao'));
    });

    test('一切正常时不触发提醒', () async {
      final notified = <List<String>>[];
      service = buildService(notifyExpired: (platforms) async => notified.add(platforms));

      await service.performManualKeepAlive();

      expect(notified, isEmpty);
    });

    test('关闭了保活的平台不打扰用户', () async {
      final notified = <List<String>>[];
      service = buildService(notifyExpired: (platforms) async => notified.add(platforms));
      auth.expired.add('taobao');
      await service.setPlatformEnabled('taobao', false);

      await service.performManualKeepAlive();

      expect(notified, isEmpty);
    });
  });

  group('快照', () {
    test('反映绑定、健康度与开关状态', () async {
      await service.performManualKeepAlive();

      final snap = service.snapshot();
      final taobao = snap.platforms.firstWhere((p) => p.platform == 'taobao');

      expect(snap.enabled, isTrue);
      expect(taobao.bound, isTrue);
      expect(taobao.enabled, isTrue);
      expect(taobao.health, '健康'); // Cookie 年龄 2 天
      expect(taobao.lastKeepAliveAt, isNotNull);
      expect(taobao.nextKeepAliveAt, isNotNull);
      expect(snap.history, isNotEmpty);
    });

    test('失效时健康度为「失效」且列入待重新授权', () async {
      auth.expired.add('taobao');

      final snap = service.snapshot();
      final taobao = snap.platforms.firstWhere((p) => p.platform == 'taobao');

      expect(taobao.health, '失效');
      expect(snap.expiredPlatforms.map((p) => p.platform), contains('taobao'));
    });
  });
}
