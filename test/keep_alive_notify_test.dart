import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:pickup_app/platform/keep_alive/keep_alive_notifier.dart';
import 'package:pickup_app/platform/notification/notification_adapter.dart';
import 'package:pickup_app/platform/storage/keep_alive_store.dart';
import 'package:pickup_app/platform/storage/platform_auth_store.dart';

/// 只实现提醒需要的读接口
class _FakeAuthStore extends PlatformAuthStore {
  final Set<String> expired = {};

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

void main() {
  late Directory tempDir;
  late _FakeAuthStore auth;
  late KeepAliveStore store;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('keep_alive_notify_test');
    Hive.init(tempDir.path);
    await KeepAliveStore.initialize();

    auth = _FakeAuthStore();
    store = KeepAliveStore();
    await store.loadIntoCache();
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('失效通知去重', () {
    test('首次失效发送一次并落盘标记', () async {
      final sent = <String>[];
      final notifier = KeepAliveNotifier(
        store: store,
        authStore: auth,
        send: (platform, displayName) async => sent.add(platform),
      );
      auth.expired.add('jd');

      expect(await notifier.notifyIfNeeded('jd'), isTrue);
      expect(sent, ['jd']);
      expect(store.lastNotifiedAt('jd'), isNotNull);
    });

    test('同一失效周期内不重复轰炸', () async {
      final sent = <String>[];
      final notifier = KeepAliveNotifier(
        store: store,
        authStore: auth,
        send: (platform, displayName) async => sent.add(platform),
      );
      auth.expired.add('jd');

      await notifier.notifyIfNeeded('jd');
      await notifier.notifyIfNeeded('jd');
      await notifier.notifyIfNeeded('jd');

      expect(sent, ['jd'], reason: '用户不该收到一串重复的失效提醒');
    });

    test('登录态恢复后再次失效，可以再提醒一次', () async {
      final sent = <String>[];
      final notifier = KeepAliveNotifier(
        store: store,
        authStore: auth,
        send: (platform, displayName) async => sent.add(platform),
      );

      auth.expired.add('jd');
      await notifier.notifyIfNeeded('jd');

      // 恢复：服务成功心跳时会清空标记
      auth.expired.remove('jd');
      await store.setLastNotifiedAt('jd', null);

      auth.expired.add('jd');
      await notifier.notifyIfNeeded('jd');

      expect(sent, ['jd', 'jd']);
    });

    test('未失效时完全不发送', () async {
      final sent = <String>[];
      final notifier = KeepAliveNotifier(
        store: store,
        authStore: auth,
        send: (platform, displayName) async => sent.add(platform),
      );

      expect(await notifier.notifyIfNeeded('jd'), isFalse);
      expect(sent, isEmpty);
    });
  });

  group('发送失败时不写标记（前台可补发）', () {
    test('抛出异常后标记保持为空，下次仍会尝试', () async {
      var attempts = 0;
      final notifier = KeepAliveNotifier(
        store: store,
        authStore: auth,
        send: (platform, displayName) async {
          attempts++;
          throw StateError('后台 isolate 无法弹通知');
        },
      );
      auth.expired.add('taobao');

      expect(await notifier.notifyIfNeeded('taobao'), isFalse);
      expect(store.lastNotifiedAt('taobao'), isNull, reason: '失败不得写标记，否则提醒会丢');

      // 下次（例如前台启动后）仍会重试
      expect(await notifier.notifyIfNeeded('taobao'), isFalse);
      expect(attempts, 2);
    });
  });

  group('通知 payload 编解码', () {
    test('保活失效 payload 可往返', () {
      final payload = NotificationAdapter.keepAliveExpiredPayload('jd');
      expect(NotificationAdapter.expiredPlatformFromPayload(payload), 'jd');
    });

    test('包裹类 payload 不被误判为保活提醒', () {
      expect(NotificationAdapter.expiredPlatformFromPayload('arrived:PDD_123'), isNull);
      expect(NotificationAdapter.expiredPlatformFromPayload('reminder:PDD_123'), isNull);
      expect(NotificationAdapter.expiredPlatformFromPayload(null), isNull);
    });
  });
}
