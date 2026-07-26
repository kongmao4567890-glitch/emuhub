import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers.dart';

/// 设置页面。
///
/// 提供检查频率、检查范围、通知、静音时段、WiFi 限制等设置项，
/// 以及关于信息。所有设置通过 [appSettingsProvider] 读写并持久化。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // === 检查设置 ===
          const _SectionHeader(title: '检查设置', icon: Icons.sync),
          const SizedBox(height: 8),
          _SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.schedule, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('自动检查频率',
                          style: theme.textTheme.bodyLarge),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SegmentedButton<CheckInterval>(
                  segments: const [
                    ButtonSegment(
                        value: CheckInterval.twoHours, label: Text('2小时')),
                    ButtonSegment(
                        value: CheckInterval.fourHours, label: Text('4小时')),
                    ButtonSegment(
                        value: CheckInterval.sixHours, label: Text('6小时')),
                    ButtonSegment(
                        value: CheckInterval.twelveHours, label: Text('12小时')),
                  ],
                  selected: {settings.checkInterval},
                  onSelectionChanged: (selected) {
                    ref.read(appSettingsProvider.notifier).updateSettings(
                          settings.copyWith(checkInterval: selected.first),
                        );
                  },
                ),
              ),
              const Divider(height: 1, indent: 16),
              RadioListTile<CheckScope>(
                title: const Text('全部模拟器'),
                subtitle: const Text('检查所有已收录的模拟器'),
                value: CheckScope.all,
                groupValue: settings.checkScope,
                onChanged: (value) {
                  if (value != null) {
                    ref.read(appSettingsProvider.notifier).updateSettings(
                          settings.copyWith(checkScope: value),
                        );
                  }
                },
              ),
              RadioListTile<CheckScope>(
                title: const Text('仅收藏'),
                subtitle: const Text('仅检查已收藏的模拟器'),
                value: CheckScope.favoritesOnly,
                groupValue: settings.checkScope,
                onChanged: (value) {
                  if (value != null) {
                    ref.read(appSettingsProvider.notifier).updateSettings(
                          settings.copyWith(checkScope: value),
                        );
                  }
                },
              ),
            ],
          ),

          const SizedBox(height: 24),

          // === 通知设置 ===
          const _SectionHeader(title: '通知设置', icon: Icons.notifications),
          const SizedBox(height: 8),
          _SettingsCard(
            children: [
              SwitchListTile(
                title: const Text('更新通知'),
                subtitle: const Text('检测到新版本时发送通知'),
                value: settings.notificationEnabled,
                onChanged: (value) {
                  ref.read(appSettingsProvider.notifier).updateSettings(
                        settings.copyWith(notificationEnabled: value),
                      );
                },
              ),
              const Divider(height: 1, indent: 16),
              ListTile(
                leading: const Icon(Icons.nightlight_round),
                title: const Text('静音时段开始'),
                subtitle: Text(settings.quietHoursStart),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _pickTime(
                  context,
                  ref,
                  settings,
                  isStart: true,
                ),
              ),
              const Divider(height: 1, indent: 16),
              ListTile(
                leading: const Icon(Icons.wb_sunny_outlined),
                title: const Text('静音时段结束'),
                subtitle: Text(settings.quietHoursEnd),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _pickTime(
                  context,
                  ref,
                  settings,
                  isStart: false,
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // === 网络与更新 ===
          const _SectionHeader(title: '网络与更新', icon: Icons.wifi),
          const SizedBox(height: 8),
          _SettingsCard(
            children: [
              SwitchListTile(
                title: const Text('仅 WiFi 下检查'),
                subtitle: const Text('移动网络下不执行更新检查'),
                value: settings.wifiOnly,
                onChanged: (value) {
                  ref.read(appSettingsProvider.notifier).updateSettings(
                        settings.copyWith(wifiOnly: value),
                      );
                },
              ),
              const Divider(height: 1, indent: 16),
              SwitchListTile(
                title: const Text('App 自身更新检查'),
                subtitle: const Text('检查 EmuHub 是否有新版本'),
                value: settings.appUpdateCheck,
                onChanged: (value) {
                  ref.read(appSettingsProvider.notifier).updateSettings(
                        settings.copyWith(appUpdateCheck: value),
                      );
                },
              ),
            ],
          ),

          const SizedBox(height: 24),

          // === 关于 ===
          const _SectionHeader(title: '关于', icon: Icons.info_outline),
          const SizedBox(height: 8),
          _SettingsCard(
            children: [
              ListTile(
                leading: const Icon(Icons.sports_esports),
                title: const Text('应用名称'),
                trailing: Text(
                  AppConstants.appName,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const Divider(height: 1, indent: 16),
              ListTile(
                leading: const Icon(Icons.verified),
                title: const Text('版本号'),
                trailing: Text(
                  'v${AppConstants.appVersion}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const Divider(height: 1, indent: 16),
              ListTile(
                leading: const Icon(Icons.code),
                title: const Text('开源协议'),
                trailing: Text(
                  'MIT License',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const Divider(height: 1, indent: 16),
              ListTile(
                leading: const Icon(Icons.source),
                title: const Text('项目仓库'),
                trailing: Text(
                  'GitHub',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                onTap: () => _launchRepo(context),
              ),
              const Divider(height: 1, indent: 16),
              ListTile(
                leading: const Icon(Icons.person),
                title: const Text('开发者'),
                trailing: Text(
                  '九尾猫游戏解说',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 32),
          Center(
            child: Text(
              '${AppConstants.appName} v${AppConstants.appVersion}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 弹出 TimePicker 选择静音时段。
  Future<void> _pickTime(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings, {
    required bool isStart,
  }) async {
    final current = isStart ? settings.quietHoursStart : settings.quietHoursEnd;
    final parts = current.split(':');
    final initial = TimeOfDay(
      hour: int.parse(parts[0]),
      minute: int.parse(parts[1]),
    );

    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: isStart ? '选择静音开始时间' : '选择静音结束时间',
    );

    if (picked != null) {
      final formatted =
          '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
      ref.read(appSettingsProvider.notifier).updateSettings(
            isStart
                ? settings.copyWith(quietHoursStart: formatted)
                : settings.copyWith(quietHoursEnd: formatted),
          );
    }
  }

  /// 打开项目仓库（简单实现，使用 url_launcher）。
  Future<void> _launchRepo(BuildContext context) async {
    final uri = Uri.parse(AppConstants.githubRepo);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开链接')),
      );
    }
  }
}

/// 分区标题。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(title, style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        )),
      ],
    );
  }
}

/// 设置卡片容器，统一圆角与背景。
class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: children,
      ),
    );
  }
}
