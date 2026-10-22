import 'package:flutter_test/flutter_test.dart';
import 'package:pickup_app/core/engine/keep_alive_plan.dart';

void main() {
  // 固定基准时间，所有用例注入它，避免依赖真实时钟
  final now = DateTime.parse('2026-10-08T10:00:00+08:00');

  group('calculateInterval 按 Cookie 年龄分档', () {
    Duration intervalDays(int days) =>
        KeepAlivePlan.calculateInterval(Duration(days: days));

    test('0-3 天 → 24 小时', () {
      expect(intervalDays(0), const Duration(hours: 24));
      expect(intervalDays(3), const Duration(hours: 24));
    });

    test('4-7 天 → 12 小时', () {
      expect(intervalDays(4), const Duration(hours: 12));
      expect(intervalDays(7), const Duration(hours: 12));
    });

    test('8-10 天 → 6 小时', () {
      expect(intervalDays(8), const Duration(hours: 6));
      expect(intervalDays(10), const Duration(hours: 6));
    });

    test('11 天及以上 → 4 小时', () {
      expect(intervalDays(11), const Duration(hours: 4));
      expect(intervalDays(90), const Duration(hours: 4));
    });

    test('不足一天按 0 天处理', () {
      expect(KeepAlivePlan.calculateInterval(const Duration(hours: 5)),
          const Duration(hours: 24));
    });
  });

  group('shouldSkip 跳过规则', () {
    test('用户 6 小时内同步过 → 跳过', () {
      expect(
        KeepAlivePlan.shouldSkip(
          lastSyncTime: now.subtract(const Duration(hours: 5, minutes: 59)),
          lastKeepAliveTime: null,
          now: now,
        ),
        isTrue,
      );
    });

    test('同步已超过 6 小时 → 不跳过', () {
      expect(
        KeepAlivePlan.shouldSkip(
          lastSyncTime: now.subtract(const Duration(hours: 6)),
          lastKeepAliveTime: null,
          now: now,
        ),
        isFalse,
      );
    });

    test('2 小时内保活过 → 跳过', () {
      expect(
        KeepAlivePlan.shouldSkip(
          lastSyncTime: null,
          lastKeepAliveTime: now.subtract(const Duration(minutes: 119)),
          now: now,
        ),
        isTrue,
      );
    });

    test('保活已超过 2 小时 → 不跳过', () {
      expect(
        KeepAlivePlan.shouldSkip(
          lastSyncTime: null,
          lastKeepAliveTime: now.subtract(const Duration(hours: 2)),
          now: now,
        ),
        isFalse,
      );
    });

    test('两项都为 null（冷启动后首次）→ 不跳过', () {
      expect(
        KeepAlivePlan.shouldSkip(
          lastSyncTime: null,
          lastKeepAliveTime: null,
          now: now,
        ),
        isFalse,
      );
    });

    test('同步很久以前但刚保活过 → 仍跳过', () {
      expect(
        KeepAlivePlan.shouldSkip(
          lastSyncTime: now.subtract(const Duration(days: 3)),
          lastKeepAliveTime: now.subtract(const Duration(minutes: 30)),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('calculateNextTime', () {
    test('无抖动时等于 now + interval', () {
      expect(
        KeepAlivePlan.calculateNextTime(const Duration(hours: 12), now: now),
        now.add(const Duration(hours: 12)),
      );
    });

    test('抖动可为正（推迟）', () {
      expect(
        KeepAlivePlan.calculateNextTime(
          const Duration(hours: 12),
          now: now,
          jitter: const Duration(minutes: 25),
        ),
        now.add(const Duration(hours: 12, minutes: 25)),
      );
    });

    test('抖动可为负（提前）', () {
      expect(
        KeepAlivePlan.calculateNextTime(
          const Duration(hours: 12),
          now: now,
          jitter: const Duration(minutes: -25),
        ),
        now.add(const Duration(hours: 11, minutes: 35)),
      );
    });
  });

  group('resolveHealth 健康度优先级', () {
    test('失效标记优先于一切', () {
      expect(
        KeepAlivePlan.resolveHealth(
          isExpired: true,
          failureCount: 0,
          cookieAge: const Duration(days: 1),
        ),
        '失效',
      );
    });

    test('连续失败达 3 次判失效', () {
      expect(
        KeepAlivePlan.resolveHealth(
          isExpired: false,
          failureCount: 3,
          cookieAge: const Duration(days: 1),
        ),
        '失效',
      );
    });

    test('连续失败 1-2 次判不稳定', () {
      expect(
        KeepAlivePlan.resolveHealth(
          isExpired: false,
          failureCount: 2,
          cookieAge: const Duration(days: 1),
        ),
        '不稳定',
      );
    });

    test('无失败时按 Cookie 年龄判定', () {
      expect(
        KeepAlivePlan.resolveHealth(
          isExpired: false,
          failureCount: 0,
          cookieAge: const Duration(days: 5),
        ),
        '良好',
      );
    });

    test('年龄未知且无失败 → unknown', () {
      expect(
        KeepAlivePlan.resolveHealth(
          isExpired: false,
          failureCount: 0,
          cookieAge: null,
        ),
        'unknown',
      );
    });
  });

  group('shouldNotifyExpiry 失效通知去重', () {
    test('失效且从未通知过 → 通知', () {
      expect(
        KeepAlivePlan.shouldNotifyExpiry(isExpired: true, lastNotifiedAt: null),
        isTrue,
      );
    });

    test('失效但本周期已通知过 → 不重复通知', () {
      expect(
        KeepAlivePlan.shouldNotifyExpiry(
          isExpired: true,
          lastNotifiedAt: now.subtract(const Duration(days: 1)),
        ),
        isFalse,
      );
    });

    test('未失效 → 不通知', () {
      expect(
        KeepAlivePlan.shouldNotifyExpiry(isExpired: false, lastNotifiedAt: null),
        isFalse,
      );
    });
  });

  group('Cookie 健康度文案与颜色', () {
    test('各年龄档文案', () {
      expect(KeepAlivePlan.cookieHealthDescription(const Duration(days: 1)), '健康');
      expect(KeepAlivePlan.cookieHealthDescription(const Duration(days: 5)), '良好');
      expect(KeepAlivePlan.cookieHealthDescription(const Duration(days: 9)), '临期');
      expect(
          KeepAlivePlan.cookieHealthDescription(const Duration(days: 12)), '需要保活');
      expect(
          KeepAlivePlan.cookieHealthDescription(const Duration(days: 20)), '即将过期');
    });

    test('颜色随年龄由绿转红', () {
      expect(KeepAlivePlan.cookieHealthColorHex(const Duration(days: 1)), '#4CAF50');
      expect(KeepAlivePlan.cookieHealthColorHex(const Duration(days: 5)), '#8BC34A');
      expect(KeepAlivePlan.cookieHealthColorHex(const Duration(days: 9)), '#FFC107');
      expect(KeepAlivePlan.cookieHealthColorHex(const Duration(days: 12)), '#FF9800');
      expect(KeepAlivePlan.cookieHealthColorHex(const Duration(days: 20)), '#F44336');
    });
  });
}
