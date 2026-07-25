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
import '../consoles/consoles_page.dart' show vendorDisplayName;
import '../emulator/emulator_detail_page.dart' show findEmulator;

/// 监听全部收藏（文件私有）。
final _favoritesStreamProvider = StreamProvider<List<Favorite>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.favoritesDao.watchAllFavorites();
});

/// 监听全部版本缓存（文件私有）。
final _cachedVersionsStreamProvider =
    StreamProvider<List<CachedVersion>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.cachedVersionsDao.watchAllCachedVersions();
});

/// 收藏页面。
///
/// 从 favorites 表读取收藏列表，按机种分组展示，支持通知开关。
class FavoritesPage extends ConsumerWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configAsync = ref.watch(emulatorsConfigProvider);
    final favoritesAsync = ref.watch(_favoritesStreamProvider);
    final cachedAsync = ref.watch(_cachedVersionsStreamProvider);
    final settings = ref.watch(appSettingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('收藏'),
        actions: [
          IconButton(
            icon: Icon(settings.notificationEnabled
                ? Icons.notifications
                : Icons.notifications_off),
            tooltip: settings.notificationEnabled ? '关闭通知' : '开启通知',
            onPressed: () {
              ref.read(appSettingsProvider.notifier).updateSettings(
                    settings.copyWith(
                      notificationEnabled: !settings.notificationEnabled,
                    ),
                  );
            },
          ),
        ],
      ),
      body: configAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _buildError(context, ref, error),
        data: (config) {
          return favoritesAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (_, __) => _buildError(context, ref, '收藏读取失败'),
            data: (favorites) {
              if (favorites.isEmpty) {
                return _buildEmptyState(context);
              }
              return cachedAsync.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (_, __) => _buildError(context, ref, '缓存读取失败'),
                data: (cached) => _buildFavoritesList(
                  context,
                  config.consoles,
                  favorites,
                  cached,
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// 构建收藏列表，按机种分组。
  Widget _buildFavoritesList(
    BuildContext context,
    List<Console> consoles,
    List<Favorite> favorites,
    List<CachedVersion> cached,
  ) {
    final theme = Theme.of(context);

    // 按 consoleId 分组
    final groups = <String, List<Favorite>>{};
    for (final fav in favorites) {
      groups.putIfAbsent(fav.consoleId, () => []).add(fav);
    }

    // 保持 favorites 的添加顺序
    final orderedConsoleIds = <String>[];
    for (final fav in favorites) {
      if (!orderedConsoleIds.contains(fav.consoleId)) {
        orderedConsoleIds.add(fav.consoleId);
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: orderedConsoleIds.length,
      itemBuilder: (context, index) {
        final consoleId = orderedConsoleIds[index];
        final groupFavorites = groups[consoleId]!;
        final console =
            consoles.cast<Console?>().firstWhere(
                  (c) => c?.id == consoleId,
                  orElse: () => null,
                );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 机种分组标题
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Row(
                children: [
                  if (console != null && console.imagePath.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.asset(
                        console.imagePath,
                        width: 24,
                        height: 24,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Text(
                          console?.icon ?? '🎮',
                          style: const TextStyle(fontSize: 18),
                        ),
                      ),
                    )
                  else
                    Text(console?.icon ?? '🎮',
                        style: const TextStyle(fontSize: 18)),
                  const SizedBox(width: 6),
                  Text(
                    console?.name ?? '未知机种',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  if (console != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      vendorDisplayName(console.vendor),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // 该机种下的收藏项
            ...groupFavorites.map((fav) {
              final result = findEmulator(consoles, fav.emulatorId);
              final emulator = result?.emulator;
              final cachedVersion = cached
                  .where((c) => c.emulatorId == fav.emulatorId)
                  .firstOrNull;
              final hasNew = cachedVersion?.isNew ?? false;
              return _FavoriteCard(
                emulator: emulator,
                emulatorId: fav.emulatorId,
                version: cachedVersion?.currentVersion ?? '',
                hasNewVersion: hasNew,
                consoleIcon: console?.icon ?? '🎮',
              );
            }),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  /// 空状态。
  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.favorite_border,
                size: 72, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 20),
            Text(
              '还没有收藏的模拟器',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '去机种库逛逛吧',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => context.push('/consoles'),
              icon: const Icon(Icons.sports_esports),
              label: const Text('前往机种库'),
            ),
          ],
        ),
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

/// 单个收藏卡片。
class _FavoriteCard extends StatelessWidget {
  const _FavoriteCard({
    required this.emulator,
    required this.emulatorId,
    required this.version,
    required this.hasNewVersion,
    required this.consoleIcon,
  });

  final Emulator? emulator;
  final String emulatorId;
  final String version;
  final bool hasNewVersion;
  final String consoleIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => context.push('/emulator/$emulatorId'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              // 图标
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius:
                      BorderRadius.circular(AppTheme.componentRadius),
                ),
                alignment: Alignment.center,
                child: Text(consoleIcon, style: const TextStyle(fontSize: 22)),
              ),
              const SizedBox(width: 12),
              // 模拟器名
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      emulator?.name ?? emulatorId,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    if (version.isNotEmpty)
                      VersionTag(version: version)
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
              // 新版徽标
              if (hasNewVersion) ...[
                const SizedBox(width: 8),
                const NewVersionBadge(),
              ],
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
