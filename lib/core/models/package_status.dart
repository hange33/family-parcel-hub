/// 包裹状态系统 - 纯Dart，不依赖Flutter
/// 
/// 职责：
/// 1. 定义包裹生命周期状态
/// 2. 提供状态转换规则
/// 3. 提供状态语义判断
/// 4. 提供紧急程度评分
library;

enum PackageStatus {
  /// 运送中 - 包裹在物流途中
  transit,
  
  /// 派送中 - 快递员正在派送
  delivering,
  
  /// 已到达 - 包裹到达取件点，等待取件
  arrived,
  
  /// 已取件 - 用户已取走包裹
  pickedUp,
  
  /// 已归档 - 已取件的包裹自动归档
  archived,

  /// 待发货 - 商品拼单成功、购买成功，商家待发货
  pendingShipment,

  /// 已拒收 - 用户拒收/包裹被退回发件人，属于终结状态
  ///
  /// 必须追加在末尾：Hive 按枚举下标序列化，插入中间会破坏已存数据的语义。
  rejected,
}

/// 状态语义扩展 - 纯业务逻辑，不依赖UI
extension PackageStatusSemantics on PackageStatus {
  /// 是否为待处理状态（需要用户关注）
  bool get isPending => this == PackageStatus.pendingShipment ||
      this == PackageStatus.transit ||
      this == PackageStatus.delivering ||
      this == PackageStatus.arrived;
  
  /// 是否为已完成状态（不需要用户关注）
  bool get isCompleted => this == PackageStatus.pickedUp ||
      this == PackageStatus.archived ||
      this == PackageStatus.rejected;

  /// 是否为已到达状态（可以取件）
  bool get isArrived => this == PackageStatus.arrived;

  /// 是否为待发货状态
  bool get isPendingShipment => this == PackageStatus.pendingShipment;

  /// 是否为已拒收（终结态，无需再取件）
  bool get isRejected => this == PackageStatus.rejected;
  
  /// 是否为活跃状态（未归档）
  bool get isActive => this != PackageStatus.archived;
  
  /// 紧急程度评分 - 用于排序和决策
  /// 越高越紧急
  int get urgencyScore {
    switch (this) {
      case PackageStatus.arrived:
        return 85;
      case PackageStatus.delivering:
        return 50;
      case PackageStatus.transit:
        return 20;
      case PackageStatus.pendingShipment:
        return 15;
      case PackageStatus.pickedUp:
        return 10;
      case PackageStatus.rejected:
        return 5;
      case PackageStatus.archived:
        return 0;
    }
  }
  
  /// 状态标签 - 用于显示
  String get label {
    switch (this) {
      case PackageStatus.pendingShipment:
        return '待发货';
      case PackageStatus.transit:
        return '运送中';
      case PackageStatus.delivering:
        return '派送中';
      case PackageStatus.arrived:
        return '待取件';
      case PackageStatus.pickedUp:
        return '已取件';
      case PackageStatus.archived:
        return '已归档';
      case PackageStatus.rejected:
        return '已拒收';
    }
  }
  
  /// 下一个可能的状态
  List<PackageStatus> get possibleNextStates {
    switch (this) {
      case PackageStatus.pendingShipment:
        return [PackageStatus.transit, PackageStatus.delivering, PackageStatus.arrived, PackageStatus.rejected];
      case PackageStatus.transit:
        return [PackageStatus.delivering, PackageStatus.arrived, PackageStatus.rejected];
      case PackageStatus.delivering:
        return [PackageStatus.arrived, PackageStatus.transit, PackageStatus.rejected];
      case PackageStatus.arrived:
        return [PackageStatus.pickedUp, PackageStatus.rejected];
      case PackageStatus.pickedUp:
        return [PackageStatus.archived];
      case PackageStatus.archived:
      case PackageStatus.rejected:
        return [];
    }
  }
  
  /// 是否可以转换到目标状态
  bool canTransitionTo(PackageStatus target) {
    return possibleNextStates.contains(target);
  }
}

/// 状态转换结果
class StatusTransition {
  final PackageStatus from;
  final PackageStatus to;
  final DateTime timestamp;
  final String? reason;
  
  const StatusTransition({
    required this.from,
    required this.to,
    required this.timestamp,
    this.reason,
  });
  
  bool get isValid => from.canTransitionTo(to);
}
