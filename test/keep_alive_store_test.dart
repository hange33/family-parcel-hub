import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:pickup_app/core/models/keep_alive_state.dart';
import 'package:pickup_app/platform/storage/keep_alive_store.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('keep_alive_store_test');
    Hive.init(tempDir.path);
    await KeepAliveStore.initialize();
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  DateTime atMs(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

  group('默认值', () {
    test('未写入任何键时：开关默认开启、无闸门、零失败', () async {
      final store = KeepAliveStore();
      await store.loadIntoCache();

      expect(store.enabled, isTrue);
      expect(store.platformEnabled('taobao'), isTrue);
      expect(store.nextAt('taobao'), isNull);
      expect(store.lastAt('taobao'), isNull);
      expect(store.failureCount('taobao'), 0);
      expect(store.lastNotifiedAt('taobao'), isNull);
      expect(store.history.records, isEmpty);
    });
  });

  group('落盘后跨实例可读（模拟进程重启）', () {
    test('标量字段全部持久化', () async {
      final a = KeepAliveStore();
      await a.loadIntoCache();

      final next = atMs(1800000000000);
      final last = atMs(1700000000000);
      await a.setNext('jd', next);
      await a.setLast('jd', last);
      await a.setFailureCount('jd', 2);
      await a.setEnabled(false);
      await a.setPlatformEnabled('jd', false);

      // 全新实例 = 重启后的进程，不共享内存缓存
      final b = KeepAliveStore();
      await b.loadIntoCache();

      expect(b.nextAt('jd'), next);
      expect(b.lastAt('jd'), last);
      expect(b.failureCount('jd'), 2);
      expect(b.enabled, isFalse);
      expect(b.platformEnabled('jd'), isFalse);
      // 未单独设置过的平台仍默认开启
      expect(b.platformEnabled('taobao'), isTrue);
    });

    test('冷启动闸门能存活：这正是「不再每次启动重发心跳」的依据', () async {
      final a = KeepAliveStore();
      await a.loadIntoCache();
      final next = atMs(DateTime.now().millisecondsSinceEpoch + 6 * 3600 * 1000);
      await a.setNext('taobao', next);

      final restarted = KeepAliveStore();
      await restarted.loadIntoCache();

      expect(restarted.nextAt('taobao'), isNotNull);
      expect(restarted.nextAt('taobao')!.isAfter(DateTime.now()), isTrue);
    });

    test('setNext(null) 清除闸门', () async {
      final store = KeepAliveStore();
      await store.loadIntoCache();
      await store.setNext('taobao', atMs(1800000000000));
      await store.clearNext('taobao');

      final reopened = KeepAliveStore();
      await reopened.loadIntoCache();
      expect(reopened.nextAt('taobao'), isNull);
    });

    test('失效通知标记可写可清', () async {
      final store = KeepAliveStore();
      await store.loadIntoCache();
      await store.setLastNotifiedAt('pdd', atMs(1700000000000));
      expect(store.lastNotifiedAt('pdd'), atMs(1700000000000));

      await store.setLastNotifiedAt('pdd', null);
      final reopened = KeepAliveStore();
      await reopened.loadIntoCache();
      expect(reopened.lastNotifiedAt('pdd'), isNull);
    });
  });

  group('保活历史', () {
    test('追加后可读，且跨实例保持', () async {
      final store = KeepAliveStore();
      await store.loadIntoCache();

      await store.appendHistory(KeepAliveRecord(
        platform: 'jd',
        time: atMs(1700000000000),
        success: true,
      ));
      await store.appendHistory(KeepAliveRecord(
        platform: 'taobao',
        time: atMs(1700000060000),
        success: false,
        authFailure: true,
        error: '登录态已失效',
      ));

      final reopened = KeepAliveStore();
      await reopened.loadIntoCache();

      expect(reopened.history.records.length, 2);
      expect(reopened.history.records.first.platform, 'taobao');
      expect(reopened.history.records.first.authFailure, isTrue);
      expect(reopened.history.records.last.platform, 'jd');
      expect(reopened.history.successRate, 0.5);
    });
  });

  group('schema 版本', () {
    test('写入后可重复调用而不报错', () async {
      final store = KeepAliveStore();
      await store.ensureSchemaVersion();
      await store.ensureSchemaVersion();
      expect(Hive.box(kKeepAliveBox).get('schema_version'), 1);
    });
  });
}
