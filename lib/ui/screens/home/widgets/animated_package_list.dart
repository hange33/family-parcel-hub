/// 首页在途包裹列表：用 [SliverAnimatedList] 管理插入 / 移除 / 重排的过渡动画。
///
/// 原先直接铺 `SliverList` 且子项没有稳定 Key，流式同步时按索引复用 Element，
/// 会出现卡片内容串位；新增项不会重新入场，被移除项则瞬间消失。
/// 这里统一交给 AnimatedList 维护：
/// - 每个包裹用 `ValueKey(package.id)` 保持身份，顺序变化不再错位；
/// - 新增项播放「展开 + 淡入」，被移除项播放「收起 + 淡出」；
/// - 首屏（初始项）沿用原有的交错入场节奏。
library;

import 'package:flutter/material.dart';

import '../../../../core/models/package.dart';
import '../../../components/staggered_entrance.dart';
import '../../../theme/motion.dart';
import 'modern_package_card.dart';

class AnimatedPackageList extends StatefulWidget {
  /// 目标包裹列表（已排序），每次变化都会与当前列表做差异同步。
  final List<Package> packages;
  final EdgeInsetsGeometry padding;

  const AnimatedPackageList({
    super.key,
    required this.packages,
    this.padding = const EdgeInsets.fromLTRB(20, 4, 20, 100),
  });

  @override
  State<AnimatedPackageList> createState() => _AnimatedPackageListState();
}

class _AnimatedPackageListState extends State<AnimatedPackageList> {
  final GlobalKey<SliverAnimatedListState> _listKey =
      GlobalKey<SliverAnimatedListState>();

  /// 当前真实存在于列表中的包裹（不含正在播放退出动画的）。
  late List<Package> _items;

  /// 首屏（初始挂载）就已在列表里的包裹 id。
  ///
  /// 这些项的入场交给 [StaggeredEntrance]；其余新增项一律走 AnimatedList 的插入动画。
  /// 用 id 而不是「首帧后翻转的开关」来判断，是为了避免重建时切换包装类型把
  /// 正在播放的交错入场动画截断。
  late final Set<String> _staggerIds;

  @override
  void initState() {
    super.initState();
    _items = List<Package>.of(widget.packages);
    _staggerIds = {for (final p in widget.packages) p.id};
  }

  @override
  void didUpdateWidget(covariant AnimatedPackageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final listState = _listKey.currentState;
    if (listState == null) {
      // 尚未完成首帧构建，直接对齐即可（随后 build 会渲染最新数据）。
      _items = List<Package>.of(widget.packages);
      return;
    }
    _syncTo(widget.packages, listState);
  }

  /// 把内部列表对齐到 [next]，并对差异部分播放入场 / 退场动画。
  ///
  /// 调用时机是 `didUpdateWidget`：此时父级正在重建，而 AnimatedList 的
  /// State 是当前 build target 的后代，其内部 `setState` 会被放行。
  void _syncTo(List<Package> next, SliverAnimatedListState listState) {
    final nextIds = next.map((p) => p.id).toSet();
    final currentIds = _items.map((p) => p.id).toSet();

    final hasRemoval = currentIds.any((id) => !nextIds.contains(id));
    final hasInsertion = nextIds.any((id) => !currentIds.contains(id));

    // 只是顺序变了（包裹状态迁移导致重排）：AnimatedList 不支持移动，
    // remove + insert 会让同一张卡片闪两下，这里直接对齐顺序。
    if (!hasRemoval && !hasInsertion) {
      _items = List<Package>.of(next);
      return;
    }

    // 1) 退场：next 中已不存在的包裹，从后往前移除并播放退出动画。
    for (var i = _items.length - 1; i >= 0; i--) {
      final pkg = _items[i];
      if (nextIds.contains(pkg.id)) continue;
      _items.removeAt(i);
      listState.removeItem(
        i,
        (context, animation) => _buildExiting(pkg, animation),
        duration: Motion.emphasized,
      );
    }

    // 2) 对齐顺序：逐位置比较，缺失的补插入场动画，已存在的仅更新数据。
    for (var i = 0; i < next.length; i++) {
      if (i < _items.length && _items[i].id == next[i].id) {
        _items[i] = next[i]; // 同一包裹的数据更新，位置不变
        continue;
      }

      final oldIndex = _items.indexWhere((p) => p.id == next[i].id);
      if (oldIndex != -1) {
        // 仍存在的项被挪了位置：直接对齐，不触发动画
        _items.insert(i, _items.removeAt(oldIndex));
      } else {
        _items.insert(i, next[i]);
        listState.insertItem(i, duration: Motion.emphasized);
      }
    }
  }

  /// 列表内正常存在的项：首屏交错入场，其余走 AnimatedList 的插入动画。
  Widget _buildItem(BuildContext context, int index, Animation<double> animation) {
    final pkg = _items[index];
    // Key 落在卡片自身而非过渡组件上：这样无论走交错入场还是 AnimatedList 插入动画，
    // ValueKey(id) 指向的都是同一个「卡片」，插入过渡是它的祖先。
    final card = Padding(
      key: ValueKey(pkg.id),
      padding: const EdgeInsets.only(bottom: 14),
      child: ModernPackageCard(package: pkg),
    );

    if (_staggerIds.contains(pkg.id)) {
      return StaggeredEntrance(index: index, child: card);
    }

    return SizeTransition(
      sizeFactor: CurvedAnimation(parent: animation, curve: Motion.standard),
      axisAlignment: -1.0,
      child: FadeTransition(opacity: animation, child: card),
    );
  }

  /// 正在退场的项：用独立 Key 包一层，避免与仍在列表中的同 id 项撞 Key。
  Widget _buildExiting(Package pkg, Animation<double> animation) {
    return SizeTransition(
      key: ValueKey('exiting_${pkg.id}'),
      sizeFactor: CurvedAnimation(parent: animation, curve: Motion.exit),
      axisAlignment: -1.0,
      child: FadeTransition(
        opacity: animation,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: ModernPackageCard(package: pkg),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: widget.padding,
      sliver: SliverAnimatedList(
        key: _listKey,
        initialItemCount: _items.length,
        itemBuilder: _buildItem,
      ),
    );
  }
}
