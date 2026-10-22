/// HeroCard状态数据结构 - 纯Dart
/// 
/// 职责：
/// 1. 定义HeroCard的状态数据
/// 2. 不依赖Flutter
/// 3. 提供结构化决策结果
library;

/// HeroCard状态
class HeroCardState {
  /// 主标题
  final String title;
  
  /// 副标题
  final String? subtitle;
  
  /// 紧急程度评分（0-100）
  final int urgencyScore;
  
  /// 情绪状态（旧版，保留兼容）
  final EmotionState emotionState;
  
  /// Hero情绪状态（新版）
  final HeroEmotionState heroEmotionState;
  
  /// 建议动作
  final SuggestedAction suggestedAction;
  
  /// 标签列表
  final List<HeroBadge> badges;
  
  /// 待处理包裹数量
  final int pendingCount;
  
  /// 已到达包裹数量
  final int arrivedCount;
  
  /// 派送中包裹数量
  final int deliveringCount;
  
  /// 运送中包裹数量
  final int transitCount;

  const HeroCardState({
    required this.title,
    this.subtitle,
    this.urgencyScore = 0,
    this.emotionState = EmotionState.calm,
    this.heroEmotionState = HeroEmotionState.relaxed,
    this.suggestedAction = SuggestedAction.none,
    this.badges = const [],
    this.pendingCount = 0,
    this.arrivedCount = 0,
    this.deliveringCount = 0,
    this.transitCount = 0,
  });

  /// 创建空状态
  factory HeroCardState.empty() {
    return const HeroCardState(
      title: '今天暂无快递',
      subtitle: null,
      urgencyScore: 0,
      emotionState: EmotionState.calm,
      heroEmotionState: HeroEmotionState.relaxed,
      suggestedAction: SuggestedAction.none,
      badges: [],
      pendingCount: 0,
      arrivedCount: 0,
      deliveringCount: 0,
      transitCount: 0,
    );
  }

  /// 是否为空状态
  bool get isEmpty => pendingCount == 0;
  
  /// 是否有紧急包裹
  bool get hasUrgentPackages => urgencyScore > 80;
  
  /// 是否有位置聚类
  bool get hasLocationCluster => badges.any((b) => b.type == HeroBadgeType.location);
  
  /// 是否建议立即取件
  bool get shouldPickUpNow => suggestedAction == SuggestedAction.pickUpNow;
  
  /// 是否建议合并取件
  bool get shouldPickUpTogether => suggestedAction == SuggestedAction.pickUpTogether;
}

/// 情绪状态（旧版，保留兼容）
enum EmotionState {
  /// 平静 - 没有紧急事务
  calm,
  
  /// 高效 - 可以合并取件
  efficient,
  
  /// 繁忙 - 有多个包裹需要处理
  busy,
  
  /// 紧急 - 需要立即处理
  urgent,
}

extension EmotionStateX on EmotionState {
  /// 情绪标签
  String get label {
    switch (this) {
      case EmotionState.calm:
        return '平静';
      case EmotionState.efficient:
        return '高效';
      case EmotionState.busy:
        return '繁忙';
      case EmotionState.urgent:
        return '紧急';
    }
  }
  
  /// 情绪评分
  int get score {
    switch (this) {
      case EmotionState.calm:
        return 0;
      case EmotionState.efficient:
        return 1;
      case EmotionState.busy:
        return 2;
      case EmotionState.urgent:
        return 3;
    }
  }
}

/// Hero情绪状态（新版）
/// 
/// 更简洁的情绪模型，直接对应用户感知：
/// - relaxed: 无待取件，今天很轻松
/// - normal: 有1~2个待取件，建议顺路取
/// - urgent: urgencyScore > 80，需要尽快处理
enum HeroEmotionState {
  /// 轻松 - 没有 arrived 包裹
  relaxed,
  
  /// 正常 - 1~2 个 arrived 包裹
  normal,
  
  /// 紧急 - urgencyScore > 80
  urgent,
}

extension HeroEmotionStateX on HeroEmotionState {
  /// 情绪标签
  String get label {
    switch (this) {
      case HeroEmotionState.relaxed:
        return '轻松';
      case HeroEmotionState.normal:
        return '正常';
      case HeroEmotionState.urgent:
        return '紧急';
    }
  }
  
  /// 情绪评分
  int get score {
    switch (this) {
      case HeroEmotionState.relaxed:
        return 0;
      case HeroEmotionState.normal:
        return 1;
      case HeroEmotionState.urgent:
        return 2;
    }
  }
  
  /// 主题描述
  String get themeDescription {
    switch (this) {
      case HeroEmotionState.relaxed:
        return '今天很轻松，暂无待取件';
      case HeroEmotionState.normal:
        return '有快递已到达，建议顺路一起取';
      case HeroEmotionState.urgent:
        return '有快递已滞留较久，建议尽快处理';
    }
  }
}

/// 建议动作
enum SuggestedAction {
  /// 无建议
  none,
  
  /// 等待
  wait,
  
  /// 立即取件
  pickUpNow,
  
  /// 合并取件
  pickUpTogether,
}

extension SuggestedActionX on SuggestedAction {
  /// 动作标签
  String get label {
    switch (this) {
      case SuggestedAction.none:
        return '无';
      case SuggestedAction.wait:
        return '等待';
      case SuggestedAction.pickUpNow:
        return '立即取件';
      case SuggestedAction.pickUpTogether:
        return '合并取件';
    }
  }
  
  /// 动作描述
  String get description {
    switch (this) {
      case SuggestedAction.none:
        return '';
      case SuggestedAction.wait:
        return '包裹还在路上，可以稍后再看';
      case SuggestedAction.pickUpNow:
        return '有紧急包裹需要立即处理';
      case SuggestedAction.pickUpTogether:
        return '多个包裹在同一地点，建议一起取';
    }
  }
}

/// HeroCard标签
class HeroBadge {
  /// 标签文本
  final String label;
  
  /// 标签类型
  final HeroBadgeType type;

  const HeroBadge({
    required this.label,
    required this.type,
  });
}

/// 标签类型
enum HeroBadgeType {
  /// 数量标签
  count,
  
  /// 紧急标签
  urgent,
  
  /// 位置标签
  location,
}
