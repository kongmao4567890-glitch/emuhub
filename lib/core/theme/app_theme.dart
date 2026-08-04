import 'package:flutter/material.dart';

/// 应用主题配置。
///
/// 基于 Material 3，以紫色为种子色生成 [ColorScheme]，亮色与暗色模式
/// 均使用系统字体，避免首次启动时依赖在线字体下载。统一约定：
/// - 卡片圆角 12
/// - 通用组件（按钮、输入框、Chip、对话框等）圆角 8
///
/// 另外提供兼容性等级对应的颜色与文案，供模拟器列表 / 详情页复用。
class AppTheme {
  AppTheme._();

  /// 亮色模式品牌种子色。
  static const Color _brandLight = Color(0xFF4B3FE3);

  /// 暗色模式品牌种子色。
  static const Color _brandDark = Color(0xFF6054F1);

  /// 成功色。
  static const Color success = Color(0xFF1DC981);

  /// 警告色。
  static const Color warning = Color(0xFFEFAA17);

  /// 危险色。
  static const Color danger = Color(0xFFE8463A);

  /// 卡片圆角半径。
  static const double cardRadius = 12;

  /// 通用组件圆角半径。
  static const double componentRadius = 8;

  /// 亮色主题。
  static ThemeData lightTheme() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _brandLight,
      brightness: Brightness.light,
    );
    return _buildTheme(colorScheme);
  }

  /// 暗色主题。
  static ThemeData darkTheme() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _brandDark,
      brightness: Brightness.dark,
    );
    return _buildTheme(colorScheme);
  }

  /// 根据 [colorScheme] 构建完整主题。
  static ThemeData _buildTheme(ColorScheme colorScheme) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: colorScheme.brightness,
    );

    final textTheme = base.textTheme;
    final primaryTextTheme = base.primaryTextTheme;

    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(cardRadius),
    );
    final componentShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(componentRadius),
    );

    return base.copyWith(
      textTheme: textTheme,
      primaryTextTheme: primaryTextTheme,
      scaffoldBackgroundColor: colorScheme.surface,
      // 卡片：圆角 12，零阴影，内容裁剪到圆角。
      cardTheme: CardThemeData(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: cardShape,
        surfaceTintColor: Colors.transparent,
      ),
      // 各类按钮：圆角 8。
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: componentShape),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: componentShape),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: componentShape),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(shape: componentShape),
      ),
      // 输入框：圆角 8，填充背景。
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(componentRadius),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(componentRadius),
          borderSide: BorderSide(color: colorScheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(componentRadius),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
      ),
      // Chip：圆角 8。
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(componentRadius),
        ),
      ),
      // 对话框 / 底部弹层：圆角 8。
      dialogTheme: DialogThemeData(shape: componentShape),
      bottomSheetTheme: BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
      ),
      // 列表项圆角 8。
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(componentRadius),
        ),
      ),
      // AppBar：无阴影、居中标题、使用品牌色。
      appBarTheme: AppBarTheme(
        centerTitle: true,
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: colorScheme.onSurface,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
      // 底部导航栏：品牌色高亮。
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colorScheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return textTheme.labelMedium?.copyWith(
            color: selected
                ? colorScheme.onPrimaryContainer
                : colorScheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          );
        }),
      ),
    );
  }

  /// 兼容性等级对应的颜色。
  ///
  /// [level] 取值：`perfect` / `high` / `good` / `medium` / `low`，
  /// 未知值返回灰色。
  static Color compatibilityColor(String level) {
    switch (level) {
      case 'perfect':
        return success;
      case 'high':
        return const Color(0xFF4B3FE3);
      case 'good':
        return const Color(0xFF22A5F7);
      case 'medium':
        return warning;
      case 'low':
        return danger;
      default:
        return Colors.grey;
    }
  }

  /// 兼容性等级对应的中文文案。
  ///
  /// [level] 取值：`perfect` / `high` / `good` / `medium` / `low`，
  /// 未知值返回“未知”。
  static String compatibilityLabel(String level) {
    switch (level) {
      case 'perfect':
        return '完美';
      case 'high':
        return '优秀';
      case 'good':
        return '良好';
      case 'medium':
        return '中等';
      case 'low':
        return '较低';
      default:
        return '未知';
    }
  }
}
