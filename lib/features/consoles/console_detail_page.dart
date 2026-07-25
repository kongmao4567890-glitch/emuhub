import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:collection/collection.dart';

import '../../core/theme/app_theme.dart';
import '../../data/database/database.dart';
import '../../data/models/console.dart';
import '../../data/models/emulator.dart';
import '../../providers.dart';
import '../../widgets/version_badge.dart';
import 'consoles_page.dart' show vendorDisplayName;

/// 监听全部版本缓存（文件私有）。
final _cachedVersionsStreamProvider =
    StreamProvider<List<CachedVersion>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.cachedVersionsDao.watchAllCachedVersions();
});

/// 机种详情页。
///
/// 接收 [consoleId]，展示机种信息与该机种下所有模拟器列表。
class ConsoleDetailPage extends ConsumerWidget {
  const ConsoleDetailPage({super.key, required this.consoleId});

  final String consoleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configAsync = ref.watch(emulatorsConfigProvider);
    final cachedVersionsAsync = ref.watch(_cachedVersionsStreamProvider);

    return configAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (error, stack) => Scaffold(
        appBar: AppBar(),
        body: _buildError(context, ref, error),
      ),
      data: (config) {
        final console = config.consoles
            .cast<Console?>()
            .firstWhere((c) => c?.id == consoleId, orElse: () => null);
        if (console == null) {
          return Scaffold(
            appBar: AppBar(),
            body: _buildNotFound(context),
          );
        }
        return cachedVersionsAsync.when(
          loading: () => Scaffold(
            appBar: AppBar(title: Text(console.name)),
            body: const Center(child: CircularProgressIndicator()),
          ),
          error: (_, __) => _buildScaffold(context, console, const []),
          data: (cached) => _buildScaffold(context, console, cached),
        );
      },
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    Console console,
    List<CachedVersion> cached,
  ) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                console.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [cs.primary, cs.primaryContainer],
                  ),
                ),
                child: Center(
                  child: Hero(
                    tag: 'console-icon-${console.id}',
                    child: Text(
                      console.icon,
                      style: const TextStyle(fontSize: 72),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 厂商 + 年份
                  Row(
                    children: [
                      _InfoChip(
                        icon: Icons.business,
                        label: vendorDisplayName(console.vendor),
                      ),
                      const SizedBox(width: 8),
                      _InfoChip(
                        icon: Icons.calendar_today,
                        label: '${console.year}',
                      ),
                      const SizedBox(width: 8),
                      _InfoChip(
                        icon: Icons.apps,
                        label: '${console.emulators.length} 个模拟器',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // 描述
                  Text('机种简介', style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  )),
                  const SizedBox(height: 8),
                  Text(
                    console.description,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 24),
                  // 模拟器列表标题
                  Text('模拟器列表', style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  )),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          // 模拟器列表
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final emulator = console.emulators[index];
                final cachedVersion = cached
                    .where((c) => c.emulatorId == emulator.id)
                    .firstOrNull;
                return Padding(
                  padding: const EdgeInsets.only(
                      left: 16, right: 16, bottom: 12),
                  child: _EmulatorListCard(
                    emulator: emulator,
                    cachedVersion: cachedVersion,
                  ),
                );
              },
              childCount: console.emulators.length,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context, WidgetRef ref, Object error) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text('数据加载失败', style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => ref.invalidate(emulatorsConfigProvider),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotFound(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off,
              size: 48, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text('未找到该机种', style: theme.textTheme.bodyLarge),
        ],
      ),
    );
  }
}

/// 信息小标签（厂商、年份等）。
class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.componentRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 模拟器列表卡片。
class _EmulatorListCard extends StatelessWidget {
  const _EmulatorListCard({
    required this.emulator,
    required this.cachedVersion,
  });

  final Emulator emulator;
  final CachedVersion? cachedVersion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final compatColor = AppTheme.compatibilityColor(emulator.compatibility);
    final hasNew = cachedVersion?.isNew ?? false;

    return Card(
      child: InkWell(
        onTap: () => context.push('/emulator/${emulator.id}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              // 左侧图标
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius:
                      BorderRadius.circular(AppTheme.componentRadius),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.sports_esports, color: cs.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              // 中间信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            emulator.name,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (hasNew) ...[
                          const SizedBox(width: 6),
                          const NewVersionBadge(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        // 开源标签
                        _Tag(
                          label: emulator.openSource ? 'GitHub' : '闭源',
                          color: emulator.openSource
                              ? AppTheme.success
                              : cs.onSurfaceVariant,
                          backgroundColor: emulator.openSource
                              ? AppTheme.success.withOpacity(0.12)
                              : cs.surfaceContainerHighest,
                        ),
                        // 兼容性标签
                        _Tag(
                          label: AppTheme.compatibilityLabel(
                              emulator.compatibility),
                          color: compatColor,
                          backgroundColor:
                              compatColor.withOpacity(0.12),
                        ),
                        // 核心名
                        if (emulator.core.isNotEmpty)
                          _Tag(
                            label: '核心: ${emulator.core}',
                            color: cs.onSurfaceVariant,
                            backgroundColor: cs.surfaceContainerHighest,
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // 当前版本
                    if (cachedVersion != null &&
                        cachedVersion!.currentVersion.isNotEmpty)
                      Row(
                        children: [
                          Icon(Icons.tag, size: 12,
                              color: cs.onSurfaceVariant),
                          const SizedBox(width: 4),
                          Text(
                            cachedVersion!.currentVersion,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      )
                    else
                      Text(
                        '暂无版本信息',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant.withOpacity(0.6),
                        ),
                      ),
                  ],
                ),
              ),
              // 右侧箭头
              Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// 小标签组件。
class _Tag extends StatelessWidget {
  const _Tag({
    required this.label,
    required this.color,
    required this.backgroundColor,
  });

  final String label;
  final Color color;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(AppTheme.componentRadius),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
