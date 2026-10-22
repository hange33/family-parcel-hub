/// 全局动效令牌：集中动画时长与曲线，避免魔法数字散落在各个组件里。
///
/// 只服务于 `ui/` 层的过渡与反馈，不承载任何业务语义。
///
/// **动效必须先有动机**。目前只承认两类动机：
/// - 反馈：用户刚做了一个动作，界面确认它（按压回弹、同步完成态）；
/// - 状态迁移：内容本身发生了变化（列表项进出场、状态胶囊换色）。
///
/// 凡是说不出动机的循环动画，都不要加。
library;

import 'package:flutter/widgets.dart';

class Motion {
  Motion._();

  /// 即时反馈：颜色微调、状态标签切换。
  static const Duration fast = Duration(milliseconds: 160);

  /// 常规过渡：淡入淡出、文案切换。
  static const Duration normal = Duration(milliseconds: 240);

  /// 强调过渡：列表项进出场、卡片展开。
  static const Duration emphasized = Duration(milliseconds: 380);

  /// 交错入场的基础间隔：第 n 项延后 `n * stagger`。
  static const Duration stagger = Duration(milliseconds: 45);

  /// 进入曲线：轻微回弹，克制收尾。
  static const Curve enter = Curves.easeOutBack;

  /// 退出曲线：加速离场，干脆利落。
  static const Curve exit = Curves.easeInCubic;

  /// 通用缓出。
  static const Curve standard = Curves.easeOutCubic;

  /// 系统「移除动画」无障碍开关是否打开。
  ///
  /// 动效强度超过 3 的场合都必须先问一次这个：位移、缩放、交错入场、
  /// 无限循环要在开启后全部塌缩为瞬时或静态。
  static bool reduce(BuildContext context) {
    final disabled = MediaQuery.maybeDisableAnimationsOf(context);
    return disabled ?? false;
  }

  /// 按时长令牌取值，开启「移除动画」时归零。
  static Duration of(BuildContext context, Duration duration) {
    return reduce(context) ? Duration.zero : duration;
  }

  /// 按曲线取值，开启「移除动画」时退化成线性（配合零时长即瞬时）。
  static Curve curve(BuildContext context, Curve curve) {
    return reduce(context) ? Curves.linear : curve;
  }
}
