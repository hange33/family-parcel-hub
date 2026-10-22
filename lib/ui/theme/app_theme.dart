import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../constants/app_constants.dart';

/// 应用主题 —— 只做一件事：把 [AppColors] / [AppRadius] 令牌翻译成 Material 主题。
///
/// 改版要点：
/// - 文本样式全部收敛到令牌，不再让页面各自内联 `TextStyle(fontSize: ...)`；
/// - 字重降一档（原先 28px/w900 的标题属于「靠字号喊话」，改由字重与颜色拉开层级）；
/// - Material 组件（SnackBar / IconButton.filledTonal / RefreshIndicator）的取色也接到令牌，
///   否则它们会走 M3 自动生成的色板，和页面里手写的颜色对不上。
class AppTheme {
  AppTheme._();

  /// 当前只提供浅色主题。
  ///
  /// 加深色主题的前提是把其余屏幕里约 200 处内联 `Color(0x...)` 迁到 [AppColors]；
  /// 只给首页做深色会让设置在深色模式下露馅，所以这一轮不做。
  /// 本文件与首页面（home / hero / package card / 公共组件）已全部走令牌。
  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
    ).copyWith(
      primary: AppColors.primaryStrong,
      onPrimary: Colors.white,
      primaryContainer: AppColors.primaryContainer,
      onPrimaryContainer: AppColors.primaryStrong,
      // IconButton.filledTonal 取这两项：改成中性浅底，避免 M3 自动色板带来的紫调。
      secondaryContainer: AppColors.surfaceSunken,
      onSecondaryContainer: AppColors.textPrimary,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      onSurfaceVariant: AppColors.textSecondary,
      outlineVariant: AppColors.separator,
      error: AppColors.statusRejected,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.background,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.separator,
        thickness: 0.5,
        space: 0,
      ),
      // RefreshIndicator 的取色没有独立主题项，它读 colorScheme.primary，
      // 上面的 scheme 已把它接到 AppColors.primaryStrong。
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.inkSurface,
        contentTextStyle: const TextStyle(
          color: AppColors.onInkPrimary,
          fontSize: 13,
          height: 1.4,
        ),
        actionTextColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.smAll),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
        ),
      ),
      splashFactory: InkSparkle.splashFactory,
      textTheme: const TextTheme(
        // Hero 主数字。颜色由调用方决定（它落在墨色表面上）。
        displaySmall: TextStyle(
          fontSize: 44,
          fontWeight: FontWeight.w800,
          height: 1.0,
          letterSpacing: -1.2,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
        headlineLarge: TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w700,
          height: 1.2,
          letterSpacing: -0.6,
          color: AppColors.textPrimary,
        ),
        headlineMedium: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          height: 1.25,
          letterSpacing: -0.3,
          color: AppColors.textPrimary,
        ),
        titleLarge: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          height: 1.3,
          color: AppColors.textPrimary,
        ),
        titleMedium: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          height: 1.35,
          color: AppColors.textPrimary,
        ),
        bodyLarge: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w400,
          height: 1.45,
          color: AppColors.textPrimary,
        ),
        bodyMedium: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          height: 1.45,
          color: AppColors.textSecondary,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          height: 1.4,
          color: AppColors.textTertiary,
        ),
        labelLarge: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
        labelMedium: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.textSecondary,
        ),
        labelSmall: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }

  static CupertinoThemeData get cupertino {
    return const CupertinoThemeData(
      brightness: Brightness.light,
      primaryColor: AppColors.primaryStrong,
      scaffoldBackgroundColor: AppColors.background,
      barBackgroundColor: AppColors.surface,
      textTheme: CupertinoTextThemeData(
        textStyle: TextStyle(fontSize: 15, color: AppColors.textPrimary),
      ),
    );
  }
}
