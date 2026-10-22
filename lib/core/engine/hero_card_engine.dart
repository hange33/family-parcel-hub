/// HeroCard决策引擎 - 纯Dart
/// 
/// 职责：
/// 1. 基于包裹状态生成HeroCard决策
/// 2. 纯逻辑，不依赖Flutter
/// 3. 输出结构化决策结果
library;

import '../models/package.dart';
import '../models/package_status.dart';
import 'hero_card_state.dart';
import 'logistics_status_engine.dart';

/// HeroCard决策引擎
class HeroCardEngine {
  /// 生成HeroCard状态
  static HeroCardState decide(List<Package> allPackages) {
    final pending = allPackages.where((p) => p.status.isPending).toList();
    
    // 0件 → 今天暂无快递
    if (pending.isEmpty) {
      return HeroCardState.empty();
    }
    
    final arrived = pending.where((p) => p.status.isArrived).toList();
    final delivering = pending.where((p) => p.status == PackageStatus.delivering).toList();
    final transit = pending.where((p) => p.status == PackageStatus.transit).toList();
    
    // 计算紧急程度
    final urgencyScore = _calculateUrgencyScore(pending);
    final emotionState = _determineEmotionState(pending, urgencyScore);
    final heroEmotionState = _determineHeroEmotionState(arrived, urgencyScore);
    
    // 生成标题和副标题
    final title = _generateTitle(arrived, delivering, transit, pending);
    final subtitle = _generateSubtitle(pending, urgencyScore);
    
    // 生成建议动作
    final suggestedAction = _generateSuggestedAction(pending, urgencyScore);
    
    // 生成标签
    final badges = _generateBadges(pending, arrived, delivering, transit);
    
    return HeroCardState(
      title: title,
      subtitle: subtitle,
      urgencyScore: urgencyScore,
      emotionState: emotionState,
      heroEmotionState: heroEmotionState,
      suggestedAction: suggestedAction,
      badges: badges,
      pendingCount: pending.length,
      arrivedCount: arrived.length,
      deliveringCount: delivering.length,
      transitCount: transit.length,
    );
  }

  /// 计算紧急程度评分
  static int _calculateUrgencyScore(List<Package> pending) {
    if (pending.isEmpty) return 0;
    
    // 基于状态的评分
    final statusScores = pending.map((p) => p.status.urgencyScore).toList();
    final maxStatusScore = statusScores.reduce((a, b) => a > b ? a : b);
    
    // 基于紧急级别的评分
    final urgencyScores = pending.map((p) => p.effectiveUrgency.score * 10).toList();
    final maxUrgencyScore = urgencyScores.reduce((a, b) => a > b ? a : b);
    
    // 综合评分
    return maxStatusScore + maxUrgencyScore;
  }

  /// 确定情绪状态（旧版）
  static EmotionState _determineEmotionState(List<Package> pending, int urgencyScore) {
    if (pending.isEmpty) return EmotionState.calm;
    
    final hasHighUrgency = urgencyScore > 80;
    final hasMultipleArrived = pending.where((p) => p.status.isArrived).length > 2;
    final hasCluster = _hasLocationCluster(pending);
    
    if (hasHighUrgency) {
      return EmotionState.urgent;
    } else if (hasMultipleArrived) {
      return EmotionState.busy;
    } else if (hasCluster) {
      return EmotionState.efficient;
    } else {
      return EmotionState.calm;
    }
  }

  /// 确定Hero情绪状态（新版）
  /// 
  /// 映射规则：
  /// - relaxed: 没有 arrived 包裹
  /// - normal: 1~2 个 arrived 包裹
  /// - urgent: urgencyScore > 80
  static HeroEmotionState _determineHeroEmotionState(
    List<Package> arrived,
    int urgencyScore,
  ) {
    // 优先判断紧急
    if (urgencyScore > 80) {
      return HeroEmotionState.urgent;
    }
    
    // 判断到达数量
    if (arrived.isEmpty) {
      return HeroEmotionState.relaxed;
    }
    
    // arrived.length >= 1 && arrived.length <= 2
    return HeroEmotionState.normal;
  }

  /// 生成标题
  static String _generateTitle(
    List<Package> arrived,
    List<Package> delivering,
    List<Package> transit,
    List<Package> pending,
  ) {
    if (arrived.isNotEmpty) {
      return '有 ${arrived.length} 件快递待取件';
    } else if (delivering.isNotEmpty) {
      return '有 ${delivering.length} 个包裹正在派送';
    } else if (transit.isNotEmpty) {
      return '有 ${transit.length} 个包裹在路上';
    } else {
      return '有 ${pending.length} 个订单待发货';
    }
  }

  /// 生成副标题
  static String? _generateSubtitle(List<Package> pending, int urgencyScore) {
    if (pending.isEmpty) return null;
    
    final hasHighUrgency = urgencyScore > 80;
    final hasCluster = _hasLocationCluster(pending);
    
    if (hasHighUrgency) {
      return '建议立即取件';
    } else if (hasCluster) {
      return '建议一起取，节省跑腿';
    } else {
      return null;
    }
  }

  /// 生成建议动作
  static SuggestedAction _generateSuggestedAction(List<Package> pending, int urgencyScore) {
    if (pending.isEmpty) {
      return SuggestedAction.none;
    }
    
    final hasHighUrgency = urgencyScore > 80;
    final hasCluster = _hasLocationCluster(pending);
    
    if (hasHighUrgency) {
      return SuggestedAction.pickUpNow;
    } else if (hasCluster) {
      return SuggestedAction.pickUpTogether;
    } else {
      return SuggestedAction.wait;
    }
  }

  /// 生成标签
  static List<HeroBadge> _generateBadges(
    List<Package> pending,
    List<Package> arrived,
    List<Package> delivering,
    List<Package> transit,
  ) {
    final badges = <HeroBadge>[];
    
    // 待处理数量
    if (pending.isNotEmpty) {
      badges.add(HeroBadge(
        label: '${pending.length} 件待处理',
        type: HeroBadgeType.count,
      ));
    }
    
    // 紧急标签
    final hasHighUrgency = pending.any((p) => p.status.urgencyScore > 80);
    if (hasHighUrgency) {
      badges.add(HeroBadge(
        label: '紧急',
        type: HeroBadgeType.urgent,
      ));
    }
    
    // 位置聚类标签
    final hasCluster = _hasLocationCluster(pending);
    if (hasCluster) {
      badges.add(HeroBadge(
        label: '可合并取件',
        type: HeroBadgeType.location,
      ));
    }
    
    return badges;
  }

  /// 检查是否有位置聚类
  static bool _hasLocationCluster(List<Package> packages) {
    final locationGroups = _groupByLocation(packages);
    return locationGroups.values.any((g) => g.length > 1);
  }

  /// 按位置分组
  static Map<String, List<Package>> _groupByLocation(List<Package> packages) {
    final map = <String, List<Package>>{};
    for (final p in packages) {
      final key = p.location.isNotEmpty ? p.location : 'unknown';
      map.putIfAbsent(key, () => []).add(p);
    }
    return map;
  }
}
