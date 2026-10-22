import 'package:flutter/material.dart';

/// 颜色令牌 —— 全应用唯一的色彩来源。
///
/// 改版约束（新增组件请照此执行，不要在内联 `Color(0x...)`）：
/// 1. **单一强调色**：有色元素只允许来自 [primary] 系、状态语义色、或平台品牌色（`PlatformBadge`）。
/// 2. **正文级文本一律过 WCAG AA**：每个文本令牌后面标了实测对比度（白底 / 画布底）。
/// 3. **画布只有一个**：[background]。页面不得再内联自己的底色。
class AppColors {
  AppColors._();

  // ── 画布与表面 ──────────────────────────────────────────────────────────
  /// 页面底色。改版前首页内联 `0xFFF6F7F9`、主题里写 `0xFFF2F2F7`，两套并存，统一到这里。
  static const background = Color(0xFFF2F2F7);
  static const surface = Color(0xFFFFFFFF);

  /// 卡片内部的次级容器底色（取件码条、空态内嵌块、图片占位）。
  static const surfaceSunken = Color(0xFFF7F7FA);

  // ── 强调色（全应用唯一）────────────────────────────────────────────────
  /// 填充、描边、图标。白字压在纯 [primary] 上只有 4.02:1，
  /// 因此它只用于非文字元素，或 ≥18px 粗体。
  static const primary = Color(0xFF007AFF);

  /// 小字号强调文本、白字实心按钮的底色。白字压其上 5.80:1，作正文色 5.80:1。
  static const primaryStrong = Color(0xFF0062CC);

  /// 强调色的浅底（选中态、行内高亮块）。
  static const primaryContainer = Color(0xFFE8F1FE);

  // ── 文本梯级 ────────────────────────────────────────────────────────────
  static const textPrimary = Color(0xFF1C1C1E); // 17.01 / 15.28
  static const textSecondary = Color(0xFF5C5C63); //  6.63 /  5.94
  static const textTertiary = Color(0xFF6E6E73); //  5.07 /  4.54

  /// 仅用于 ≥18px 或纯装饰图标。**不得承载正文**：白底只有 2.21:1。
  static const textDisabled = Color(0xFFAEAEB2);

  static const separator = Color(0xFFE3E3E8);
  static const border = Color(0xFFE3E3E8);

  // ── 状态语义色 ──────────────────────────────────────────────────────────
  // 每个前景色都保证：作为文本压在自己的 12% 浅底上 ≥ 4.5:1。
  // 唯一的真源是 `theme/status_extension.dart`，这里只给色值。
  static const statusPendingShipment = Color(0xFF4A46B8); // 6.10
  static const statusTransit = Color(0xFF55555C); // 6.18
  static const statusDelivering = Color(0xFF8A4A00); // 5.72
  static const statusArrived = Color(0xFF0062CC); // 4.85
  static const statusPickedUp = Color(0xFF116B33); // 5.52
  static const statusArchived = Color(0xFF6B6B70); // 4.54

  /// 拒收是终结异常态：实心红底 + 白字（5.62:1）。
  static const statusRejected = Color(0xFFC62828);

  // ── 墨色表面（首页 Hero）────────────────────────────────────────────────
  static const inkSurface = Color(0xFF17171A);
  static const inkSurfaceRaised = Color(0xFF232327);
  static const onInkPrimary = Color(0xFFFFFFFF); // 17.89
  static const onInkSecondary = Color(0xB8FFFFFF); // white 72% → 10.9
  static const onInkTertiary = Color(0x9EFFFFFF); // white 62% →  7.5
  static const onInkDivider = Color(0x1FFFFFFF);

  // ── 兼容别名 ────────────────────────────────────────────────────────────
  // 供 `app/hero_decision.dart` 等既有模块引用，语义统一收敛到上面的状态色。
  static const secondary = Color(0xFF5856D6);
  static const destructive = statusRejected;
  static const error = statusRejected;
  static const urgent = statusRejected;
  static const success = statusPickedUp;
  static const warning = statusDelivering;
  static const info = primary;

  static const urgentBg = Color(0xFFFFE9E7);
  static const warningBg = Color(0xFFFFF3E4);
  static const successBg = Color(0xFFE6F4EA);
}

/// 间距令牌 —— 8 的倍数为主，4 为半档。
class AppSpacing {
  AppSpacing._();

  static const xxs = 2.0;
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const xxxl = 32.0;
}

/// 圆角令牌 —— 全应用只有这一套（Shape Consistency Lock）。
///
/// 改版前页面里同时散落着 6 / 8 / 10 / 12 / 16 / 18 / 20 / 22 / 24 九种圆角，
/// 没有规则可循。现在按「元素层级」固定映射：
/// 标签 8 → 内嵌容器 12 → 卡片 16 → 大表面 20。
class AppRadius {
  AppRadius._();

  /// 标签、徽标、胶囊内的小方块。
  static const xs = 8.0;

  /// 卡片内部的分组容器、图片缩略图、输入框。
  static const sm = 12.0;

  /// 卡片本体。
  static const md = 16.0;

  /// Hero 表面、空态大块、底部抽屉。
  static const lg = 20.0;

  /// 胶囊形（同步按钮、状态胶囊）。
  static const pill = 999.0;

  static BorderRadius get xsAll => BorderRadius.circular(xs);
  static BorderRadius get smAll => BorderRadius.circular(sm);
  static BorderRadius get mdAll => BorderRadius.circular(md);
  static BorderRadius get lgAll => BorderRadius.circular(lg);
  static BorderRadius get pillAll => BorderRadius.circular(pill);
}
