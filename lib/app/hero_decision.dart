library;

import 'package:flutter/material.dart';
import '../ui/constants/app_constants.dart';
import '../core/models/package.dart';
import '../core/engine/hero_card_engine.dart';
import '../core/engine/hero_card_state.dart';

export '../core/engine/hero_card_state.dart'
    show HeroBadgeType, EmotionState, SuggestedAction, HeroEmotionState;

class HeroBadge {
  final String label;
  final HeroBadgeType type;

  const HeroBadge({required this.label, required this.type});
}

class HeroDecision {
  final String title;
  final String? subtitle;
  final List<HeroBadge> badges;
  final IconData icon;
  final Color color;

  /// 结构化计数 —— 由 core 的 [HeroCardEngine] 算好，UI 只负责摆位置。
  ///
  /// 这些字段原先在 `_convert` 里被丢掉了，只留下拼好的 [title] 句子，
  /// 于是首页仪表盘只好自己用 `where(...)` 重新数了一遍：
  /// 同一套判定在 core 和 UI 里各写了一份，且两边的「待取件」配色还互相矛盾。
  final int arrivedCount;
  final int deliveringCount;
  final int transitCount;
  final int pendingShipmentCount;

  /// 全部在途与待取之和。
  final int pendingCount;

  final int urgencyScore;
  final HeroEmotionState heroEmotionState;
  final SuggestedAction suggestedAction;

  const HeroDecision({
    required this.title,
    this.subtitle,
    this.badges = const [],
    this.icon = Icons.local_shipping_outlined,
    this.color = AppColors.primary,
    this.arrivedCount = 0,
    this.deliveringCount = 0,
    this.transitCount = 0,
    this.pendingShipmentCount = 0,
    this.pendingCount = 0,
    this.urgencyScore = 0,
    this.heroEmotionState = HeroEmotionState.relaxed,
    this.suggestedAction = SuggestedAction.none,
  });

  /// 是否有需要在途 / 待取的包裹。
  bool get isEmpty => pendingCount == 0;

  /// 首页 Hero 该把哪个数字放到最大。
  ///
  /// 顺序即「用户下一步该关心什么」：先看有没有到了要取的，再看有没有正在送的，
  /// 再看路上的，最后才是还没发货的。
  ({int count, String unit}) get lead {
    if (arrivedCount > 0) return (count: arrivedCount, unit: '件待取');
    if (deliveringCount > 0) return (count: deliveringCount, unit: '件派送中');
    if (transitCount > 0) return (count: transitCount, unit: '件在途');
    return (count: pendingShipmentCount, unit: '件待发货');
  }
}

class HeroDecisionService {
  static HeroDecision decide(List<Package> allPackages) {
    final coreState = HeroCardEngine.decide(allPackages);
    return _convert(coreState);
  }

  static HeroDecision _convert(HeroCardState state) {
    final badges = state.badges
        .map((b) => HeroBadge(label: b.label, type: b.type))
        .toList();

    // core 的 pendingCount 覆盖 pendingShipment / transit / delivering / arrived，
    // 待发货数由差值还原（引擎没有单独输出这一项）。
    final pendingShipmentCount = state.pendingCount -
        state.arrivedCount -
        state.deliveringCount -
        state.transitCount;

    return HeroDecision(
      title: state.title,
      subtitle: state.subtitle,
      badges: badges,
      icon: _icon(state.heroEmotionState),
      color: _color(state.heroEmotionState),
      arrivedCount: state.arrivedCount,
      deliveringCount: state.deliveringCount,
      transitCount: state.transitCount,
      pendingShipmentCount: pendingShipmentCount < 0 ? 0 : pendingShipmentCount,
      pendingCount: state.pendingCount,
      urgencyScore: state.urgencyScore,
      heroEmotionState: state.heroEmotionState,
      suggestedAction: state.suggestedAction,
    );
  }

  static Color _color(HeroEmotionState emotion) {
    switch (emotion) {
      case HeroEmotionState.relaxed:
        return AppColors.success;
      case HeroEmotionState.normal:
        return AppColors.primary;
      case HeroEmotionState.urgent:
        return AppColors.urgent;
    }
  }

  static IconData _icon(HeroEmotionState emotion) {
    switch (emotion) {
      case HeroEmotionState.relaxed:
        return Icons.check_circle_outline;
      case HeroEmotionState.normal:
        return Icons.local_shipping_outlined;
      case HeroEmotionState.urgent:
        return Icons.warning_amber_rounded;
    }
  }
}