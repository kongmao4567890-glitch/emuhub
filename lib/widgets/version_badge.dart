import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// "新版" 徽标。
///
/// 绿色圆角小标签，用于卡片右上角标识该模拟器存在尚未查看的新版本。
class NewVersionBadge extends StatelessWidget {
  const NewVersionBadge({super.key, this.label = '新版'});

  /// 徽标文案，默认为 "新版"。
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.success,
        borderRadius: BorderRadius.circular(AppTheme.componentRadius),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
    );
  }
}

/// 版本号小标签。
///
/// 以 Chip 形式展示版本号，用于机种卡片、模拟器列表等位置。
class VersionTag extends StatelessWidget {
  const VersionTag({
    super.key,
    required this.version,
    this.icon = Icons.tag,
    this.backgroundColor,
  });

  /// 要展示的版本号字符串。
  final String version;

  /// 标签前缀图标，默认为 tag 图标。
  final IconData icon;

  /// 自定义背景色，为空时使用主题 surfaceContainerHighest。
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = backgroundColor ?? theme.colorScheme.surfaceContainerHighest;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppTheme.componentRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            version,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
