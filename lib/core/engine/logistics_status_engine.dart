/// 纯 Dart 物流状态推断引擎
///
/// 职责：
/// 1. 基于时间排序的轨迹节点流与订单生命周期，推导精确的 PackageStatus。
/// 2. 区分主状态与异常 Overlay，支持置信度评分。
/// 3. 严格禁止引入 Flutter SDK、Platform 或 UI 依赖。
library;

import '../models/package.dart';
import '../models/package_status.dart';

/// 内部事件动作分类
enum LogisticsNodeAction {
  signed,
  rejected,
  waitingPickup,
  outForDelivery,
  inTransit,
  exception,
  unknown,
}

/// 时间轴状态稳定性等级
enum LogisticsStability {
  rapidChange, // 高频变化（派送中 / 刚到站待取）：状态极不稳定，随时可能送达或取件
  active,      // 活跃推进（近期有干线推进）：运输活跃
  steady,      // 平稳在途（长途干线中转中）：相对稳定
  quiescent,   // 静态备货（已购买 / 待发货）：商家备货
  settled,     // 终结态（已签收 / 已拒收）：完全稳定
}

/// 状态推导结果
class DerivedDeliveryStatus {
  final PackageStatus status;
  final bool hasException;
  final String? exceptionReason;
  final double confidence;
  final LogisticsStability stability;
  final Duration recommendedSyncInterval;

  const DerivedDeliveryStatus({
    required this.status,
    this.hasException = false,
    this.exceptionReason,
    this.confidence = 1.0,
    this.stability = LogisticsStability.steady,
    this.recommendedSyncInterval = const Duration(minutes: 30),
  });

  String get stabilityName {
    switch (stability) {
      case LogisticsStability.rapidChange:
        return '高频变化';
      case LogisticsStability.active:
        return '活跃推进';
      case LogisticsStability.steady:
        return '平稳在途';
      case LogisticsStability.quiescent:
        return '静态备货';
      case LogisticsStability.settled:
        return '完全终结';
    }
  }
}

class LogisticsStatusEngine {
  /// 核心推导入口
  static DerivedDeliveryStatus derive({
    required List<Map<String, String>> events,
    bool isPendingShipment = false,
    bool isOrderSigned = false,
    String pickupCode = '',
    String stationName = '',
  }) {
    // 0. 最新轨迹明确为拒收/退回：属于终结态，必须优先于列表侧的签收文案与取件码
    if (events.isNotEmpty) {
      final newest = '${events.first['tag'] ?? ''} ${events.first['text'] ?? ''}'.trim();
      if (isRejectionSignal(newest)) {
        return DerivedDeliveryStatus(
          status: PackageStatus.rejected,
          hasException: true,
          exceptionReason: events.first['text'],
          confidence: 0.95,
          stability: LogisticsStability.settled,
          recommendedSyncInterval: const Duration(days: 365),
        );
      }
    }

    // 1. 订单生命周期明确为已签收/交易成功
    if (isOrderSigned) {
      return const DerivedDeliveryStatus(
        status: PackageStatus.pickedUp,
        confidence: 1.0,
        stability: LogisticsStability.settled,
        recommendedSyncInterval: Duration(days: 365),
      );
    }

    // 2. 订单生命周期明确为待发货（成团未出库）
    if (isPendingShipment && events.isEmpty) {
      return const DerivedDeliveryStatus(
        status: PackageStatus.pendingShipment,
        confidence: 1.0,
        stability: LogisticsStability.quiescent,
        recommendedSyncInterval: Duration(hours: 3),
      );
    }

    // 3. 拥有明确有效取件码（货架码/单号后五位等）且非待发货
    if (pickupCode.trim().isNotEmpty && !isPendingShipment) {
      return const DerivedDeliveryStatus(
        status: PackageStatus.arrived,
        confidence: 0.95,
        stability: LogisticsStability.rapidChange,
        recommendedSyncInterval: Duration(minutes: 10),
      );
    }

    // 4. 遍历多节点轨迹流（从最新到最旧依次扫描）
    LogisticsNodeAction? baseAction;
    String? exceptionText;

    for (final node in events) {
      final text = node['text'] ?? '';
      final tag = node['tag'] ?? '';
      final combined = '$tag $text'.trim();
      if (combined.isEmpty) continue;

      final action = classifyNode(combined);

      if (action == LogisticsNodeAction.rejected) {
        // 拒收/退回是终结态：一旦出现在轨迹中即定案，不再继续寻找基态
        baseAction = LogisticsNodeAction.rejected;
        exceptionText ??= text;
        break;
      }

      if (action == LogisticsNodeAction.exception) {
        exceptionText ??= text;
        continue; // 异常记录后继续向下寻找基态
      }

      if (action == LogisticsNodeAction.signed) {
        baseAction = LogisticsNodeAction.signed;
        break;
      }

      if (action == LogisticsNodeAction.waitingPickup) {
        baseAction = LogisticsNodeAction.waitingPickup;
        break;
      }

      if (action == LogisticsNodeAction.outForDelivery) {
        baseAction = LogisticsNodeAction.outForDelivery;
        break;
      }

      if (action == LogisticsNodeAction.inTransit && baseAction == null) {
        baseAction = LogisticsNodeAction.inTransit;
      }
    }

    // 5. 映射至最终对外状态
    PackageStatus resolvedStatus;
    switch (baseAction) {
      case LogisticsNodeAction.signed:
        resolvedStatus = PackageStatus.pickedUp;
        break;
      case LogisticsNodeAction.waitingPickup:
        resolvedStatus = PackageStatus.arrived;
        break;
      case LogisticsNodeAction.outForDelivery:
        resolvedStatus = PackageStatus.delivering;
        break;
      case LogisticsNodeAction.inTransit:
        resolvedStatus = PackageStatus.transit;
        break;
      case LogisticsNodeAction.rejected:
        resolvedStatus = PackageStatus.rejected;
        break;
      case LogisticsNodeAction.exception:
      case LogisticsNodeAction.unknown:
      case null:
        resolvedStatus = isPendingShipment ? PackageStatus.pendingShipment : PackageStatus.transit;
        break;
    }

    LogisticsStability stability;
    Duration syncInterval;
    switch (resolvedStatus) {
      case PackageStatus.delivering:
        stability = LogisticsStability.rapidChange;
        syncInterval = const Duration(minutes: 5);
        break;
      case PackageStatus.arrived:
        stability = LogisticsStability.rapidChange;
        syncInterval = const Duration(minutes: 10);
        break;
      case PackageStatus.transit:
        DateTime? latestNodeTime;
        if (events.isNotEmpty) {
          final tStr = events.first['time'] ?? '';
          latestNodeTime = DateTime.tryParse(tStr.replaceAll('/', '-'));
        }
        final now = DateTime.now();
        if (latestNodeTime != null && now.difference(latestNodeTime).inHours < 2) {
          stability = LogisticsStability.active;
          syncInterval = const Duration(minutes: 20);
        } else {
          stability = LogisticsStability.steady;
          syncInterval = const Duration(minutes: 60);
        }
        break;
      case PackageStatus.pendingShipment:
        stability = LogisticsStability.quiescent;
        syncInterval = const Duration(hours: 3);
        break;
      case PackageStatus.pickedUp:
      case PackageStatus.archived:
      case PackageStatus.rejected:
        stability = LogisticsStability.settled;
        syncInterval = const Duration(days: 365);
        break;
    }

    return DerivedDeliveryStatus(
      status: resolvedStatus,
      hasException: exceptionText != null,
      exceptionReason: exceptionText,
      confidence: baseAction != null ? 0.9 : 0.6,
      stability: stability,
      recommendedSyncInterval: syncInterval,
    );
  }

  /// 是否为「拒收 / 退回发件人」信号（拒收属于终结态，不再投递）
  ///
  /// 注意：不能收录「退货」这类词——拼多多商品文案常见「退货包运费」，
  /// 误判会让正常在途包裹变成拒收。
  static bool isRejectionSignal(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    return _containsAny(t, const [
      '拒收', '已退回', '退回发件人', '退件', '已退件',
    ]);
  }

  /// 单节点文本分类
  static LogisticsNodeAction classifyNode(String text) {
    final t = text.trim();
    if (t.isEmpty) return LogisticsNodeAction.unknown;

    // A0. 拒收/退回（终结态，优先于签收与到件）
    if (isRejectionSignal(t)) {
      return LogisticsNodeAction.rejected;
    }

    // A. 签收动作（最高终态）
    if (_containsAny(t, const [
      '已签收', '签收成功', '本人签收', '代收人已签收', '已取件', '已妥投', '妥投签收',
    ])) {
      return LogisticsNodeAction.signed;
    }

    // B. 自提点/驿站到件待取动作（待取件）
    // 注意：转运中心干线到件不属于自提点待取
    final isTransferStation = t.contains('转运中心') || t.contains('分拨中心') || t.contains('集散中心') || t.contains('分拣中心');
    final hasArrivalSignal = _containsAny(t, const [
      '已派送至', '待取件', '待自提', '已入库', '已到站', '已到驿站', '出示单号', '取件码', '凭码取件', '凭提货码', '代收点', '自提点',
    ]);
    if (hasArrivalSignal && !isTransferStation) {
      return LogisticsNodeAction.waitingPickup;
    }

    // C. 派送中（正在派送动作）
    // 严谨纠偏：只有明确出现派件员派件中才算；到达/发往末端网点仍属于运输中
    if (_containsAny(t, const [
      '派件中', '派送中', '正在派件', '正在派送', '正在为您派件', '配送员正在配送', '快递员已开始派送',
    ])) {
      return LogisticsNodeAction.outForDelivery;
    }

    // D. 异常动作
    if (_containsAny(t, const [
      '派送失败', '无人接收', '联系不上', '拒收', '退回', '退件', '地址错误', '无法配送',
    ])) {
      return LogisticsNodeAction.exception;
    }

    // E. 运输中（发往、离开、到达转运中心、到达网点等）
    if (_containsAny(t, const [
      '运输中', '运输途中', '已发往', '发往', '已离开', '离开', '已揽收', '揽收',
      '已发出', '发出', '到达', '转运中心', '分拨中心', '分拣中心', '营业部', '网点',
    ])) {
      return LogisticsNodeAction.inTransit;
    }

    return LogisticsNodeAction.unknown;
  }

  // ── 取件码展示与急件（P11-b 后续，产品经理、技术负责人 10-07 定）────────────────
  //
  // 签收后不显示取件码、不标急件。过滤只在这一层做：连接器和存储里的原始 pickupCode 保留不动，
  // 界面、排序、提醒统一读这里给出的「有效取件码」和「是否急件」（或 Package 上的同名扩展 getter）。

  /// 取件已结束：已签收 / 已归档 / 已拒收，不再需要取件码。
  static bool isPickupClosed(PackageStatus status) => status.isCompleted;

  /// 有效取件码：取件已结束时为空串，否则为去掉首尾空白的原始取件码。
  static String effectivePickupCode({required PackageStatus status, required String pickupCode}) =>
      isPickupClosed(status) ? '' : pickupCode.trim();

  /// 是否急件：取件未结束，且已到站或已拿到取件码（待发货除外）。
  ///
  /// 和首页「待取件」口径一致（已到达，或未完成且已有取件码）。
  static bool isUrgent({required PackageStatus status, required String pickupCode}) {
    if (isPickupClosed(status) || status == PackageStatus.pendingShipment) return false;
    if (status == PackageStatus.arrived) return true;
    return effectivePickupCode(status: status, pickupCode: pickupCode).isNotEmpty;
  }

  /// 统一的紧急程度：急件 → urgent；取件已结束 → low；其余沿用 [fallback]，
  /// 但 fallback 是 urgent 时降为 normal（急件只由本规则给出，避免历史合并留下的 urgent 残留）。
  static UrgencyLevel urgencyFor({
    required PackageStatus status,
    required String pickupCode,
    UrgencyLevel fallback = UrgencyLevel.normal,
  }) {
    if (isUrgent(status: status, pickupCode: pickupCode)) return UrgencyLevel.urgent;
    if (isPickupClosed(status)) return UrgencyLevel.low;
    return fallback == UrgencyLevel.urgent ? UrgencyLevel.normal : fallback;
  }

  static bool _containsAny(String source, List<String> targets) {
    for (final target in targets) {
      if (source.contains(target)) return true;
    }
    return false;
  }
}

/// 界面读取取件码与急件的入口（纯 Dart）。
///
/// 前端显示取件码读 [displayPickupCode]（不要直接读 `pickupCode`）；判断急件读 [isUrgentNow]；
/// 需要紧急级别时读 [effectiveUrgency]（存储里的 `urgency` 可能是历史合并留下的 urgent）。
extension PackagePickupDisplay on Package {
  /// 要显示的取件码：已签收 / 已归档 / 已拒收时为空串
  String get displayPickupCode =>
      LogisticsStatusEngine.effectivePickupCode(status: status, pickupCode: pickupCode);

  /// 当前是否急件：已签收 / 已归档 / 已拒收时为 false
  bool get isUrgentNow => LogisticsStatusEngine.isUrgent(status: status, pickupCode: pickupCode);

  /// 当前紧急级别（由引擎按状态和取件码推导）
  UrgencyLevel get effectiveUrgency =>
      LogisticsStatusEngine.urgencyFor(status: status, pickupCode: pickupCode, fallback: urgency);
}
