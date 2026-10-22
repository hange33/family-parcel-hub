/// 包裹状态的视觉映射 —— **全应用唯一的真源**。
///
/// 职责：
/// 1. 把 [PackageStatus] 映射成颜色（前景 / 浅底）与是否实心；
/// 2. 不包含任何业务逻辑（标签文案取自 core 的 `PackageStatusSemantics.label`）。
///
/// 改版前这套映射有两份且互相矛盾：本文件（无任何引用）说 `arrived` 是红色 `#FF3B30`，
/// 而 `modern_package_card.dart` 自己写的私有映射说 `arrived` 是蓝色 `#007AFF`。
/// 现在只保留这一份，卡片直接复用。
///
/// 对比度：每个前景色压在自己的 12% 浅底上均 ≥ 4.5:1（WCAG AA），实测值见注释。
library;

import 'package:flutter/material.dart';
import '../constants/app_constants.dart';
import '../../core/models/package_status.dart';

/// 状态视觉属性扩展
extension PackageStatusUI on PackageStatus {
  /// 前景色：用于文字、图标、描边。
  Color get color {
    switch (this) {
      case PackageStatus.pendingShipment:
        return AppColors.statusPendingShipment; // 6.10
      case PackageStatus.transit:
        return AppColors.statusTransit; // 6.18
      case PackageStatus.delivering:
        return AppColors.statusDelivering; // 5.72
      case PackageStatus.arrived:
        // 待取件是最需要用户行动的状态，用强调色而非警示红。
        return AppColors.statusArrived; // 4.85
      case PackageStatus.pickedUp:
        return AppColors.statusPickedUp; // 5.52
      case PackageStatus.rejected:
        // 拒收是终结异常态，实心红底白字（5.62:1），明显区别于其它浅底标签。
        return AppColors.statusRejected;
      case PackageStatus.archived:
        return AppColors.statusArchived; // 4.54
    }
  }

  /// 浅底：12% 前景色。压在白卡片上时，文字对比度即 [color] 注释里的实测值。
  Color get bgColor => color.withValues(alpha: 0.12);

  /// 是否使用实心底 + 反白文字。
  bool get isSolidPill => this == PackageStatus.rejected;

  /// 胶囊内的文字颜色。
  Color get pillForeground => isSolidPill ? Colors.white : color;

  /// 胶囊底色。
  Color get pillBackground => isSolidPill ? color : bgColor;
}
