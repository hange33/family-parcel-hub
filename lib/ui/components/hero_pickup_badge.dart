/// 大号醒目取件码徽标 - 支持一键复制与触觉反馈
///
/// 取件码是这个 App 里最重要的一条信息（用户就是来读它的），所以它值得：
/// - 更大的字号（18 / 24），而不是塞在 16px 里；
/// - 等宽数字 + 字距，避免不同数字宽度导致复制时看串位；
/// - 实心强调色底 + 白字，白字对比 5.80:1（WCAG AA）。
///
/// 改版去掉了原先的蓝色外发光阴影与一个从未被读取的 `_morphController`。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants/app_constants.dart';
import '../theme/motion.dart';

class HeroPickupBadge extends StatefulWidget {
  final String pickupCode;
  final bool isLarge;
  final VoidCallback? onCopied;

  const HeroPickupBadge({
    super.key,
    required this.pickupCode,
    this.isLarge = false,
    this.onCopied,
  });

  @override
  State<HeroPickupBadge> createState() => _HeroPickupBadgeState();
}

class _HeroPickupBadgeState extends State<HeroPickupBadge> {
  bool _isCopied = false;

  Future<void> _handleCopy() async {
    if (widget.pickupCode.trim().isEmpty) return;

    await Clipboard.setData(ClipboardData(text: widget.pickupCode));
    HapticFeedback.mediumImpact();

    if (!mounted) return;
    setState(() => _isCopied = true);
    widget.onCopied?.call();

    await Future.delayed(const Duration(milliseconds: 1800));
    if (mounted) setState(() => _isCopied = false);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pickupCode.trim().isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: AppColors.surfaceSunken,
          borderRadius: AppRadius.xsAll,
        ),
        child: const Text(
          '待到站生成',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.textTertiary,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    final fontSize = widget.isLarge ? 22.0 : 18.0;
    final fill = _isCopied ? AppColors.statusPickedUp : AppColors.primaryStrong;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _handleCopy,
        borderRadius: AppRadius.xsAll,
        child: AnimatedContainer(
          duration: Motion.of(context, Motion.fast),
          curve: Motion.standard,
          padding: EdgeInsets.symmetric(
            horizontal: widget.isLarge ? 14 : AppSpacing.md,
            vertical: widget.isLarge ? AppSpacing.sm : 6,
          ),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: AppRadius.xsAll,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _isCopied ? Icons.check_rounded : Icons.copy_rounded,
                size: fontSize * 0.8,
                color: Colors.white,
              ),
              const SizedBox(width: 6),
              // 徽标可能被放进很窄的容器（详情抽屉里它和驿站信息并排）。
              // 允许文字收缩并省略，好过整块 Row 直接报溢出 —— 点击复制仍拿到完整取件码。
              Flexible(
                child: AnimatedCrossFade(
                  firstChild: Text(
                    widget.pickupCode,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                      height: 1.15,
                      color: Colors.white,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  secondChild: Text(
                    '已复制',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: fontSize * 0.85,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  crossFadeState: _isCopied
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  duration: Motion.of(context, Motion.fast),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
