/// 流式交错入场动画组件 - 用于多平台增量数据返回时的优雅渐进呈现
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/motion.dart';

class StaggeredEntrance extends StatefulWidget {
  final Widget child;
  final int index;
  final Duration duration;
  final Duration baseDelay;
  final double verticalOffset;

  const StaggeredEntrance({
    super.key,
    required this.child,
    required this.index,
    this.duration = Motion.emphasized,
    this.baseDelay = Motion.stagger,
    this.verticalOffset = 16.0,
  });

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;

  /// 延迟启动的定时器：组件提前销毁时必须取消，避免对已释放的控制器动手。
  Timer? _startTimer;

  /// 入场只调度一次。放在 didChangeDependencies 是因为是否「移除动画」
  /// 只能从 MediaQuery 读，而那是个依赖型查询，initState 里不允许调用。
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Motion.standard,
    );

    _slideAnimation = Tween<Offset>(
      begin: Offset(0, widget.verticalOffset / 100),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Motion.enter,
    ));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scheduled) return;
    _scheduled = true;

    if (Motion.reduce(context)) {
      // 移除动画：不延迟、不位移，直接就是终态。
      _controller.value = 1.0;
      return;
    }

    _startTimer = Timer(widget.baseDelay * widget.index, () {
      if (mounted) {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: SlideTransition(
          position: _slideAnimation,
          child: widget.child,
        ),
      ),
    );
  }
}
