/// 带有弹簧物理触感与按压回弹的现代卡片组件
library;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../constants/app_constants.dart';
import '../theme/motion.dart';

class SpringCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressScale;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final BorderRadius? borderRadius;
  final Border? border;
  final List<BoxShadow>? boxShadow;

  const SpringCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressScale = 0.975,
    this.padding = EdgeInsets.zero,
    this.color,
    this.borderRadius,
    this.border,
    this.boxShadow,
  });

  @override
  State<SpringCard> createState() => _SpringCardState();
}

class _SpringCardState extends State<SpringCard> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _scaleAnimation;

  /// 弹簧物理模拟器参数：轻盈、迅速、自然收尾（不再超弹，避免整屏卡片一起晃）。
  final _springDesc = const SpringDescription(
    mass: 1.0,
    stiffness: 520.0,
    damping: 32.0,
  );

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(vsync: this);
    _scaleAnimation = _controller.drive(
      Tween<double>(begin: 1.0, end: widget.pressScale),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails details) {
    if (widget.onTap == null && widget.onLongPress == null) return;
    // 这里**不再**触发触觉反馈：onTapDown 在滚动起手时也会命中，
    // 于是在列表上滑动会被反复震一下。触觉交给真正响应动作的一方去发。
    if (Motion.reduce(context)) {
      // 移除动画：直接落到按下态，不做插值。
      _controller.value = 1.0;
      return;
    }
    final simulation = SpringSimulation(_springDesc, _controller.value, 1.0, 0.0);
    _controller.animateWith(simulation);
  }

  void _handleTapUp(TapUpDetails details) {
    _releaseSpring();
    widget.onTap?.call();
  }

  void _handleTapCancel() {
    _releaseSpring();
  }

  void _releaseSpring() {
    if (Motion.reduce(context)) {
      _controller.value = 0.0;
      return;
    }
    final simulation = SpringSimulation(_springDesc, _controller.value, 0.0, 0.0);
    _controller.animateWith(simulation);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cardBorderRadius = widget.borderRadius ?? AppRadius.mdAll;

    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        onLongPress: widget.onLongPress,
        child: AnimatedBuilder(
          animation: _scaleAnimation,
          builder: (context, child) => Transform.scale(
            scale: _scaleAnimation.value,
            alignment: Alignment.center,
            child: child,
          ),
          child: Container(
            padding: widget.padding,
            decoration: BoxDecoration(
              color: widget.color ?? theme.colorScheme.surface,
              borderRadius: cardBorderRadius,
              border: widget.border,
              boxShadow: widget.boxShadow ??
                  [
                    // 投影带一点背景色调，不用纯黑（纯黑投影在浅底上会发脏）。
                    BoxShadow(
                      color: const Color(0xFF2C2C2E).withValues(alpha: 0.05),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
