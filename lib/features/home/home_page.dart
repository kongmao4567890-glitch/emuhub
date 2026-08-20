import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../data/database/database.dart';
import '../../data/models/console.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers.dart';
import '../../widgets/version_badge.dart';
import '../app_update/app_update_prompt.dart';
import '../emulator/emulator_detail_page.dart' show findEmulator;
import '../news/news_widgets.dart';

/// 监听全部版本缓存（文件私有），供首页 "最近更新" 区域使用。
final _cachedVersionsStreamProvider =
    StreamProvider<List<CachedVersion>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.cachedVersionsDao.watchAllCachedVersions();
});

/// 首页。
///
/// 展示欢迎卡片、"最近更新" 横向卡片、"推荐机种" 卡片以及快捷入口按钮。
/// 首次打开应用时自动触发一次更新检查。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  /// 推荐机种 id 列表。
  static const List<String> _recommendedConsoleIds = <String>[
    'fc',
    'sfc',
    'gba',
    'ps1',
    'ps2',
    'switch',
    'neogeo',
    'psvita',
    'multi_system',
  ];

  /// 是否已完成首次更新检查（防止重复触发）。
  bool _firstLaunchCheckDone = false;
  bool _appUpdateCheckStarted = false;

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(emulatorsConfigProvider);
    final cachedVersionsAsync =
        ref.watch(_cachedVersionsStreamProvider);

    if (!_appUpdateCheckStarted) {
      _appUpdateCheckStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) checkAndShowAppUpdate(context, ref);
      });
    }

    // 配置加载完成后，触发首次更新检查。
    // 必须在帧结束后触发：_checkUpdatesOnFirstLaunch 会同步调用
    // ScaffoldMessenger.showSnackBar，在 build 阶段直接调用会触发
    // "setState() called during build" 错误。
    if (!_firstLaunchCheckDone) {
      final config = configAsync.valueOrNull;
      if (config != null) {
        _firstLaunchCheckDone = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _checkUpdatesOnFirstLaunch(config.consoles);
          }
        });
      }
    }

    return Scaffold(
      body: SafeArea(
        child: configAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => _buildError(context, error),
          data: (config) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                const _WelcomeCard(),
                const SizedBox(height: 24),
                const _LatestNewsSection(),
                const SizedBox(height: 24),
                cachedVersionsAsync.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                  data: (cached) =>
                      _RecentUpdatesSection(cached: cached, consoles: config.consoles),
                ),
                const SizedBox(height: 24),
                _RecommendedConsolesSection(
                  consoles: config.consoles
                      .where((c) => _recommendedConsoleIds.contains(c.id))
                      .toList(),
                ),
                const SizedBox(height: 24),
                const _QuickEntriesSection(),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 首次启动时自动检查更新，并通过 SnackBar 提示结果。
  Future<void> _checkUpdatesOnFirstLaunch(List<Console> consoles) async {
    if (!mounted) return;

    final settings = ref.read(appSettingsProvider);
    final db = ref.read(appDatabaseProvider);
    final cached = await db.cachedVersionsDao.getAllCachedVersions();
    final freshnessCutoff = DateTime.now()
        .subtract(settings.checkIntervalDuration)
        .millisecondsSinceEpoch;

    // 后台任务或近期的前台检查已经完成时，不要在每次回到首页后再次
    // 请求上百个数据源。手动检查仍可在“更新中心”随时强制执行。
    if (cached.any((entry) => entry.lastCheckedAt >= freshnessCutoff)) {
      return;
    }

    var targets = consoles.expand((c) => c.emulators).toList();
    if (settings.checkScope == CheckScope.favoritesOnly) {
      final favorites = await db.favoritesDao.getAllFavorites();
      final favoriteIds = favorites.map((f) => f.emulatorId).toSet();
      targets = targets.where((e) => favoriteIds.contains(e.id)).toList();
    }

    if (targets.isEmpty || !mounted) return;

    // 显示检查中的 SnackBar
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('正在检查模拟器更新…'),
          ],
        ),
        duration: Duration(seconds: 10),
      ),
    );

    try {
      final updateService = ref.read(updateServiceProvider);
      final result = await updateService.checkAll(targets);

      if (!mounted) return;

      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      final message = result.hasUpdates
          ? '发现 ${result.updated.length} 个新版本！共检查 ${result.checked} 个模拟器'
              '${result.failed.isNotEmpty ? '，${result.failed.length} 个检查失败' : ''}'
          : '所有 ${result.checked} 个模拟器均为最新版本'
              '${result.failed.isNotEmpty ? '，${result.failed.length} 个检查失败' : ''}';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                result.hasUpdates ? Icons.new_releases : Icons.check_circle,
                size: 18,
                color: result.hasUpdates
                    ? AppTheme.success
                    : Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(message)),
            ],
          ),
          duration: const Duration(seconds: 4),
          action: result.hasUpdates
              ? SnackBarAction(
                  label: '查看',
                  onPressed: () => context.push('/updates'),
                )
              : null,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('更新检查失败，请稍后重试'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Widget _buildError(BuildContext context, Object error) {
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
            const SizedBox(height: 8),
            Text(
              error.toString(),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
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
}

/// 首页新闻只展示重点内容，完整筛选和长文阅读放在独立新闻页。
class _LatestNewsSection extends ConsumerWidget {
  const _LatestNewsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final feedAsync = ref.watch(newsFeedProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.newspaper, color: theme.colorScheme.primary, size: 20),
            const SizedBox(width: 8),
            Text(
              '最新资讯',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => context.push('/news'),
              child: const Text('查看全部'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        feedAsync.when(
          loading: () => const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, __) => Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppTheme.cardRadius),
            ),
            child: Row(
              children: [
                const Expanded(child: Text('资讯暂时无法加载，可稍后重试')),
                TextButton(
                  onPressed: () {
                    ref.invalidate(newsServiceProvider);
                    ref.invalidate(newsFeedProvider);
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
          data: (feed) {
            final articles = feed.articles.take(3).toList(growable: false);
            if (articles.isEmpty) return const Text('暂无资讯');
            return Column(
              children: [
                NewsArticleCard(article: articles.first),
                for (final article in articles.skip(1))
                  NewsArticleCard(article: article, compact: true),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// 顶部欢迎卡片。
class _WelcomeCard extends StatelessWidget {
  const _WelcomeCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [cs.primary, cs.primaryContainer],
        ),
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.sports_esports, color: cs.onPrimary, size: 32),
              const SizedBox(width: 12),
              Text(
                AppConstants.appName,
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: cs.onPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '一站式追踪模拟器版本更新',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: cs.onPrimary.withOpacity(0.9),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '覆盖从 Atari 到 Switch 的全世代主机与掌机',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onPrimary.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }
}

/// "最近更新" 区域：横向滚动卡片，展示有新版本的模拟器。
class _RecentUpdatesSection extends StatelessWidget {
  const _RecentUpdatesSection({
    required this.cached,
    required this.consoles,
  });

  final List<CachedVersion> cached;
  final List<Console> consoles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final updates =
        cached.where((c) => c.isNew && c.currentVersion.isNotEmpty).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.new_releases, color: AppTheme.success, size: 20),
            const SizedBox(width: 8),
            Text('最近更新', style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            )),
          ],
        ),
        const SizedBox(height: 12),
        if (updates.isEmpty)
          _buildEmpty(theme)
        else
          SizedBox(
            height: 110,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: updates.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final item = updates[index];
                return _RecentUpdateCard(cached: item, consoles: consoles);
              },
            ),
          ),
      ],
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline,
              color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '暂无新版本更新，所有模拟器均为最新',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单张 "最近更新" 横向卡片。
class _RecentUpdateCard extends StatelessWidget {
  const _RecentUpdateCard({required this.cached, required this.consoles});

  final CachedVersion cached;
  final List<Console> consoles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final result = findEmulator(consoles, cached.emulatorId);
    final emulator = result?.emulator;
    final console = result?.console;
    final releaseDate = cached.lastReleaseDate != null
        ? DateFormat('MM-dd').format(
            DateTime.fromMillisecondsSinceEpoch(cached.lastReleaseDate!))
        : '--';
    return GestureDetector(
      onTap: () => context.push('/emulator/${cached.emulatorId}'),
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppTheme.cardRadius),
          border: Border.all(
            color: AppTheme.success.withOpacity(0.3),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 机种小图片缩略图
                if (console != null && console.imagePath.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.asset(
                      console.imagePath,
                      width: 20,
                      height: 20,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Text(
                        console.icon,
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  )
                else
                  Text(console?.icon ?? '🎮', style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    console?.name ?? '未知机种',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                const NewVersionBadge(),
              ],
            ),
            const Spacer(),
            Text(
              emulator?.name ?? cached.emulatorId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  cached.currentVersion,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: AppTheme.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  releaseDate,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "推荐机种" 区域。
class _RecommendedConsolesSection extends StatelessWidget {
  const _RecommendedConsolesSection({required this.consoles});

  final List<Console> consoles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.local_fire_department,
                color: theme.colorScheme.primary, size: 20),
            const SizedBox(width: 8),
            Text('推荐机种', style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            )),
          ],
        ),
        const SizedBox(height: 12),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 1.0,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: consoles.length,
          itemBuilder: (context, index) {
            final console = consoles[index];
            return _RecommendedConsoleCard(console: console);
          },
        ),
      ],
    );
  }
}

/// 推荐机种卡片（图片 + 底部文字叠加）。
class _RecommendedConsoleCard extends StatelessWidget {
  const _RecommendedConsoleCard({required this.console});

  final Console console;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return GestureDetector(
      onTap: () => context.push('/console/${console.id}'),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 机种真实图片
            console.imagePath.isNotEmpty
                ? Image.asset(
                    console.imagePath,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildEmojiBg(cs),
                  )
                : _buildEmojiBg(cs),
            // 底部渐变遮罩 + 文字
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.7),
                    ],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      console.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${console.year}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white.withOpacity(0.8),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 无图片时回退到 emoji 背景。
  Widget _buildEmojiBg(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: Text(console.icon, style: const TextStyle(fontSize: 32)),
      ),
    );
  }
}

/// 快捷入口按钮区域。
class _QuickEntriesSection extends StatelessWidget {
  const _QuickEntriesSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('快捷入口', style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
        )),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _QuickEntryCard(
                icon: Icons.system_update,
                title: '更新中心',
                subtitle: '查看新版本',
                onTap: () => context.push('/updates'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _QuickEntryCard(
                icon: Icons.sports_esports,
                title: '机种库',
                subtitle: '浏览全部机种',
                onTap: () => context.push('/consoles'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 单个快捷入口卡片。
class _QuickEntryCard extends StatelessWidget {
  const _QuickEntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        ),
        child: Row(
          children: [
            Icon(icon, color: cs.onPrimaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: cs.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onPrimaryContainer.withOpacity(0.8),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: cs.onPrimaryContainer),
          ],
        ),
      ),
    );
  }
}
