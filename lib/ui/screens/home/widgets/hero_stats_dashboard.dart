/// 首页顶部 Hero —— 只回答一个问题：现在最该关心几件包裹。
///
/// 改版前的三个问题：
/// 1. **没用 core 的决策结果**。`HeroCardEngine` 已经算出 arrivedCount / deliveringCount /
///    urgencyScore / 「建议一起取」这类结论，也接进了 `heroDecisionProvider`，但仪表盘
///    自己在 widget 里又 `where(...)` 数了一遍，且两边对「待取件」的配色还相反。
///    现在只读 [heroDecisionProvider]。
/// 2. **把 Hero 写成了功能清单**。原先一屏里塞了三个数字、两根竖分隔线、一句解释，
///    再加一个同步按钮。Hero 是一个瞬间，不是列表：现在只留「主数字 + 一句话」。
/// 3. **拿 `fontFamily: 'monospace'` 撑数字、拿 `FittedBox` 补溢出**。
///    改用等宽数字特性（tabular figures），字号按最长内容预留，不需要缩放兜底。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/hero_decision.dart';
import '../../../constants/app_constants.dart';
import '../../../providers/package_provider.dart';
import '../../../theme/motion.dart';

class HeroStatsDashboard extends ConsumerWidget {
  const HeroStatsDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final decision = ref.watch(heroDecisionProvider);

    // 没有在途 / 待取件时整块收起，让位给页面下方的空态卡片。
    // 两处都讲「现在没有包裹」是重复的。
    if (decision.isEmpty) return const SizedBox.shrink();

    final lead = decision.lead;
    final theme = Theme.of(context);
    final isUrgent = decision.heroEmotionState == HeroEmotionState.urgent;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: AppColors.inkSurface,
        borderRadius: AppRadius.lgAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              _RollingNumber(
                value: lead.count,
                style: theme.textTheme.displaySmall!.copyWith(
                  color: AppColors.onInkPrimary,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                lead.unit,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onInkPrimary,
                ),
              ),
              const Spacer(),
              // 全页最多一个语义标签，且只在紧急时出现。
              if (isUrgent) const _UrgentChip(),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            _statusLine(decision),
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: AppColors.onInkTertiary,
            ),
          ),
        ],
      ),
    );
  }

  /// 一句话说明当前状态。
  ///
  /// 优先用 core 给的建议（「建议立即取件」「建议一起取，节省跑腿」），
  /// 没有建议时退回一句朴素的状态描述。
  String _statusLine(HeroDecision decision) {
    final advice = decision.subtitle;
    if (advice != null && advice.isNotEmpty) return advice;

    final lead = decision.lead;
    if (decision.arrivedCount > 0) return '已送达驿站，点击卡片查看取件码';
    if (decision.deliveringCount > 0) return '快递员正在派送，留意来电';
    if (decision.transitCount > 0) return '包裹运送中，到站后会第一时间提醒';
    if (lead.count > 0) return '商家正在备货，发货后自动同步';
    return '';
  }
}

/// 紧急标签：仅在 `urgencyScore > 80` 时出现。
///
/// 用实心强调红 + 白字（5.62:1），而不是一个彩色小圆点 —— 圆点不传达任何信息。
class _UrgentChip extends StatelessWidget {
  const _UrgentChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: AppColors.statusRejected,
        borderRadius: AppRadius.xsAll,
      ),
      child: const Text(
        '紧急',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 数字滚动：数值变化时在旧值与新值之间插值，避免整块数字硬跳。
///
/// 动机是「状态迁移」——同步回来后数量变了，用户需要看见它变了。
/// 系统开启「移除动画」时直接落到终值。
class _RollingNumber extends StatelessWidget {
  final int value;
  final TextStyle style;

  const _RollingNumber({required this.value, required this.style});

  @override
  Widget build(BuildContext context) {
    final duration = Motion.of(context, Motion.emphasized);
    if (duration == Duration.zero) {
      return Text(value.toString(), style: style);
    }

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: value.toDouble()),
      duration: duration,
      curve: Motion.standard,
      builder: (context, animated, _) => Text(
        animated.round().toString(),
        style: style,
      ),
    );
  }
}
