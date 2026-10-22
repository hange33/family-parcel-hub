import 'package:flutter_test/flutter_test.dart';
import 'package:pickup_app/core/models/keep_alive_state.dart';

void main() {
  final t0 = DateTime.parse('2026-10-08T10:00:00+08:00');

  KeepAliveRecord rec(
    String platform, {
    required bool success,
    bool authFailure = false,
    bool skipped = false,
    String? error,
    int minutesAgo = 0,
  }) =>
      KeepAliveRecord(
        platform: platform,
        time: t0.subtract(Duration(minutes: minutesAgo)),
        success: success,
        authFailure: authFailure,
        skipped: skipped,
        error: error,
      );

  group('KeepAliveHistory.appended', () {
    test('新记录排在最前', () {
      final h = KeepAliveHistory.empty
          .appended(rec('jd', success: true))
          .appended(rec('taobao', success: true));
      expect(h.records.first.platform, 'taobao');
      expect(h.records.last.platform, 'jd');
    });

    test('超过上限时截断并保留最新的', () {
      var h = KeepAliveHistory.empty;
      for (var i = 0; i < 60; i++) {
        h = h.appended(rec('jd', success: true, minutesAgo: 60 - i), cap: 50);
      }
      expect(h.records.length, 50);
      // 最后追加的那条（i=59，1 分钟前）最新，仍在队首
      expect(h.records.first.time, t0.subtract(const Duration(minutes: 1)));
      // 最老的 10 条（i=0..9，60~51 分钟前）已被淘汰
      expect(
        h.records.any((r) => r.time == t0.subtract(const Duration(minutes: 60))),
        isFalse,
      );
      expect(h.records.last.time, t0.subtract(const Duration(minutes: 50)));
    });

    test('不修改原对象（不可变）', () {
      final original = KeepAliveHistory.empty.appended(rec('jd', success: true));
      final next = original.appended(rec('taobao', success: true));
      expect(original.records.length, 1);
      expect(next.records.length, 2);
    });
  });

  group('KeepAliveHistory.successRate', () {
    test('空历史返回 null', () {
      expect(KeepAliveHistory.empty.successRate, isNull);
    });

    test('全部成功 → 1.0', () {
      final h = KeepAliveHistory.empty
          .appended(rec('jd', success: true))
          .appended(rec('jd', success: true));
      expect(h.successRate, 1.0);
    });

    test('一半成功 → 0.5', () {
      final h = KeepAliveHistory.empty
          .appended(rec('jd', success: true))
          .appended(rec('jd', success: false));
      expect(h.successRate, 0.5);
    });

    test('跳过的记录不参与统计', () {
      final h = KeepAliveHistory.empty
          .appended(rec('jd', success: true))
          .appended(rec('pdd', success: true, skipped: true))
          .appended(rec('pdd', success: true, skipped: true));
      // 只剩 1 条有效记录且成功
      expect(h.successRate, 1.0);
    });

    test('全部跳过 → null（无有效样本）', () {
      final h = KeepAliveHistory.empty.appended(rec('pdd', success: true, skipped: true));
      expect(h.successRate, isNull);
    });
  });

  group('KeepAliveHistory JSON 往返', () {
    test('字段完整往返', () {
      final h = KeepAliveHistory.empty
          .appended(rec('jd', success: false, authFailure: true, error: '登录态已失效'))
          .appended(rec('pdd', success: true, skipped: true));

      final restored = KeepAliveHistory.fromJson(h.toJson());

      expect(restored.records.length, 2);
      expect(restored.records.first.platform, 'pdd');
      expect(restored.records.first.skipped, isTrue);
      expect(restored.records.last.platform, 'jd');
      expect(restored.records.last.authFailure, isTrue);
      expect(restored.records.last.error, '登录态已失效');
      expect(restored.records.last.time, t0);
    });

    test('空列表往返', () {
      expect(KeepAliveHistory.fromJson(const []).records, isEmpty);
    });

    test('非法条目被忽略而非抛错', () {
      expect(KeepAliveHistory.fromJson(const ['not-a-map', 42]).records, isEmpty);
    });
  });

  group('KeepAliveSnapshot.expiredPlatforms', () {
    PlatformKeepAliveStatus status(String p, {bool bound = true, bool expired = false}) =>
        PlatformKeepAliveStatus(
          platform: p,
          bound: bound,
          enabled: true,
          cookieAge: const Duration(days: 2),
          lastKeepAliveAt: null,
          nextKeepAliveAt: null,
          failureCount: 0,
          isExpired: expired,
          health: expired ? '失效' : '健康',
        );

    test('只挑出已绑定且失效的平台', () {
      const snap = KeepAliveSnapshot(
        enabled: true,
        platforms: [],
        history: [],
        lastCheckAt: null,
      );
      final withPlatforms = KeepAliveSnapshot(
        enabled: snap.enabled,
        platforms: [
          status('taobao'),
          status('jd', expired: true),
          status('pdd', bound: false, expired: true), // 未绑定不算
        ],
        history: const [],
        lastCheckAt: null,
      );

      final expired = withPlatforms.expiredPlatforms;
      expect(expired.length, 1);
      expect(expired.first.platform, 'jd');
    });
  });
}
