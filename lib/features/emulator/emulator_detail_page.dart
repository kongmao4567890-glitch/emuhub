import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../data/database/database.dart';
import '../../data/models/console.dart';
import '../../data/models/emulator.dart';
import '../../providers.dart';
import '../../services/download/download_resolver.dart';
import '../../services/update/release_notes_translator.dart';
import '../../widgets/version_badge.dart';
import '../consoles/consoles_page.dart' show vendorDisplayName;

/// 监听指定模拟器的版本缓存（文件私有）。
final _cachedVersionProvider =
    StreamProvider.family<CachedVersion?, String>((ref, emulatorId) {
  final db = ref.watch(appDatabaseProvider);
  return db.cachedVersionsDao.watchCachedVersion(emulatorId);
});

/// 监听指定模拟器的收藏状态（文件私有）。
final _isFavoriteProvider =
    StreamProvider.family<bool, String>((ref, emulatorId) {
  final db = ref.watch(appDatabaseProvider);
  return db.favoritesDao.watchAllFavorites().map(
        (favorites) => favorites.any((f) => f.emulatorId == emulatorId),
      );
});

/// 数据来源标签。
String sourceTypeLabel(String sourceType) {
  switch (sourceType) {
    case 'github':
      return 'GitHub';
    case 'gitlab':
      return 'GitLab';
    case 'playstore':
      return 'Google Play';
    case 'website':
      return '官网';
    default:
      return '未知';
  }
}

/// 在全部机种中查找指定模拟器，返回 (机种, 模拟器) 或 null。
({Console console, Emulator emulator})? findEmulator(
  List<Console> consoles,
  String emulatorId,
) {
  for (final console in consoles) {
    for (final emulator in console.emulators) {
      if (emulator.id == emulatorId) {
        return (console: console, emulator: emulator);
      }
    }
  }
  return null;
}

/// 模拟器详情页。
///
/// 接收 [emulatorId]，展示模拟器信息、版本、下载源与收藏操作。
class EmulatorDetailPage extends ConsumerWidget {
  const EmulatorDetailPage({super.key, required this.emulatorId});

  final String emulatorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configAsync = ref.watch(emulatorsConfigProvider);
    final cachedAsync = ref.watch(_cachedVersionProvider(emulatorId));
    final isFavAsync = ref.watch(_isFavoriteProvider(emulatorId));

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
        final result = findEmulator(config.consoles, emulatorId);
        if (result == null) {
          return Scaffold(
            appBar: AppBar(),
            body: _buildNotFound(context),
          );
        }
        final console = result.console;
        final emulator = result.emulator;

        try {
          return _buildDetailContent(
              context, ref, console, emulator, cachedAsync, isFavAsync);
        } catch (e, stack) {
          debugPrint('EmulatorDetailPage build error: $e');
          debugPrint('Stack: $stack');
          return Scaffold(
            appBar: AppBar(title: Text(emulator.name)),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline, size: 48, color: Colors.red),
                    const SizedBox(height: 12),
                    Text('页面渲染出错', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      e.toString(),
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => ref.invalidate(emulatorsConfigProvider),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
      },
    );
  }

  /// 构建详情页主体内容。
  Widget _buildDetailContent(
    BuildContext context,
    WidgetRef ref,
    Console console,
    Emulator emulator,
    AsyncValue<CachedVersion?> cachedAsync,
    AsyncValue<bool> isFavAsync,
  ) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          _buildSliverAppBar(context, console, emulator),
          SliverToBoxAdapter(
            child: cachedAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, stack) {
                debugPrint('emulator_detail_page: cachedAsync error: $error');
                debugPrint('Stack: $stack');
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildHeaderInfo(context, console, emulator, null),
                      const SizedBox(height: 20),
                      _buildVersionSection(context, null),
                      const SizedBox(height: 20),
                      _buildAttributes(context, emulator),
                      const SizedBox(height: 20),
                      _buildDescription(context, emulator),
                      const SizedBox(height: 20),
                      _buildDownloadButtons(context, emulator, null),
                      const SizedBox(height: 16),
                      _buildFavoriteButton(
                          context, ref, isFavAsync, console.id),
                      const SizedBox(height: 32),
                    ],
                  ),
                );
              },
              data: (cached) => Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeaderInfo(context, console, emulator, cached),
                    const SizedBox(height: 20),
                    _buildVersionSection(context, cached),
                    const SizedBox(height: 20),
                    _buildAttributes(context, emulator),
                    const SizedBox(height: 20),
                    _buildDescription(context, emulator),
                    const SizedBox(height: 20),
                    _buildDownloadButtons(context, emulator, cached),
                    const SizedBox(height: 16),
                    _buildFavoriteButton(
                        context, ref, isFavAsync, console.id),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部 SliverAppBar，带机种真实图片作为 Hero 图标。
  Widget _buildSliverAppBar(
    BuildContext context,
    Console console,
    Emulator emulator,
  ) {
    final cs = Theme.of(context).colorScheme;
    return SliverAppBar(
      expandedHeight: 240,
      pinned: true,
      flexibleSpace: FlexibleSpaceBar(
        title: Text(
          emulator.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        background: console.imagePath.isNotEmpty
            ? Hero(
                tag: 'emulator-console-${console.id}',
                child: Image.asset(
                  console.imagePath,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _buildGradientBg(cs, console.icon),
                ),
              )
            : _buildGradientBg(cs, console.icon),
      ),
    );
  }

  /// 渐变背景 + emoji 回退。
  Widget _buildGradientBg(ColorScheme cs, String icon) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [cs.primary, cs.primaryContainer],
        ),
      ),
      child: Center(
        child: Text(icon, style: const TextStyle(fontSize: 72)),
      ),
    );
  }

  /// 头部信息：所属机种 + 来源标签。
  Widget _buildHeaderInfo(
    BuildContext context,
    Console console,
    Emulator emulator,
    CachedVersion? cached,
  ) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.sports_esports, size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              '${console.name} · ${vendorDisplayName(console.vendor)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _InfoPill(
              icon: _sourceIcon(emulator.sourceType),
              label: sourceTypeLabel(emulator.sourceType),
            ),
            _InfoPill(
              icon: emulator.openSource ? Icons.lock_open : Icons.lock,
              label: emulator.openSource ? '开源' : '闭源',
              color: emulator.openSource ? AppTheme.success : cs.onSurfaceVariant,
            ),
            if (cached?.isNew ?? false)
              const NewVersionBadge(),
          ],
        ),
      ],
    );
  }

  /// 版本信息区域：当前版本 + 发布日期 + 更新说明。
  Widget _buildVersionSection(BuildContext context, CachedVersion? cached) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('版本信息', style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
        )),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: cached == null || cached.currentVersion.isEmpty
                ? Row(
                    children: [
                      Icon(Icons.history, color: cs.onSurfaceVariant),
                      const SizedBox(width: 12),
                      Text('暂无版本信息，请检查更新',
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: cs.onSurfaceVariant)),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.tag, color: cs.primary),
                          const SizedBox(width: 8),
                          Text(
                            cached.currentVersion,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: cached.isNew ? AppTheme.success : null,
                            ),
                          ),
                          if (cached.isNew) ...[
                            const SizedBox(width: 8),
                            const NewVersionBadge(),
                          ],
                        ],
                      ),
                      if (cached.lastReleaseDate != null) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(Icons.event, size: 16,
                                color: cs.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Text(
                              '发布日期：${DateFormat('yyyy-MM-dd').format(
                                DateTime.fromMillisecondsSinceEpoch(
                                    cached.lastReleaseDate!),
                              )}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (cached.lastCheckedAt > 0) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.update, size: 16,
                                color: cs.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Text(
                              '上次检查：${DateFormat('yyyy-MM-dd HH:mm').format(
                                DateTime.fromMillisecondsSinceEpoch(
                                    cached.lastCheckedAt),
                              )}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (cached.releaseNotes != null &&
                          cached.releaseNotes!.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        const Divider(),
                        const SizedBox(height: 8),
                        Text('更新说明', style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        )),
                        const SizedBox(height: 4),
                        Text(
                          ReleaseNotesTranslator.translate(cached.releaseNotes) ??
                              cached.releaseNotes!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  /// 属性区域：兼容性、最低 Android、核心、开源状态。
  Widget _buildAttributes(BuildContext context, Emulator emulator) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('基本信息', style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
        )),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              _AttributeTile(
                icon: Icons.verified,
                title: '兼容性',
                trailing: _CompatibilityTag(level: emulator.compatibility),
              ),
              const Divider(height: 1, indent: 16),
              _AttributeTile(
                icon: Icons.android,
                title: '最低 Android 版本',
                trailing: Text(
                  emulator.minAndroid,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const Divider(height: 1, indent: 16),
              _AttributeTile(
                icon: Icons.code,
                title: '核心',
                trailing: Text(
                  emulator.core.isEmpty ? '无' : emulator.core,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const Divider(height: 1, indent: 16),
              _AttributeTile(
                icon: emulator.openSource ? Icons.lock_open : Icons.lock,
                title: '开源状态',
                trailing: Text(
                  emulator.openSource ? '开源' : '闭源',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: emulator.openSource ? AppTheme.success : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 模拟器描述。
  Widget _buildDescription(BuildContext context, Emulator emulator) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('模拟器简介', style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
        )),
        const SizedBox(height: 8),
        Text(
          emulator.description,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
            height: 1.6,
          ),
        ),
      ],
    );
  }

  /// 下载源按钮（含稳定版、开发版、每夜版三个渠道）。
  ///
  /// 优先使用缓存中的动态下载链接（由适配器在版本检查时解析），
  /// 避免模拟器更新后静态 URL 404。
  Widget _buildDownloadButtons(
    BuildContext context,
    Emulator emulator,
    CachedVersion? cached,
  ) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    // 解析动态下载链接
    final latestVersion = cached?.currentVersion;
    final cachedDownloadUrl = cached?.resolvedDownloadUrl;
    final cachedDevDownloadUrl = cached?.resolvedDevDownloadUrl;

    final stableUrl = DownloadResolver.resolveStableUrl(
      emulator,
      cachedDownloadUrl: cachedDownloadUrl,
      latestVersion: latestVersion,
    );
    final devUrl = DownloadResolver.resolveDevUrl(
      emulator,
      cachedDevDownloadUrl: cachedDevDownloadUrl,
      latestVersion: latestVersion,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('下载源', style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
        )),
        const SizedBox(height: 12),
        // 稳定版直接下载 APK
        if (stableUrl.isNotEmpty) ...[
          _DownloadChannelCard(
            icon: Icons.download,
            label: '稳定版（最新发布）',
            description: '经过测试的稳定版本',
            url: stableUrl,
            color: cs.primary,
            isPrimary: true,
          ),
          const SizedBox(height: 8),
        ],
        // 开发版/预览版
        if (devUrl.isNotEmpty) ...[
          _DownloadChannelCard(
            icon: Icons.developer_mode,
            label: '开发版（最新预览）',
            description: cachedDevDownloadUrl != null && cachedDevDownloadUrl.isNotEmpty
                ? '包含最新功能，直接下载 APK'
                : '包含最新功能，可能不稳定',
            url: devUrl,
            color: Colors.orange,
          ),
          // 开发版更新说明
          if (cached?.resolvedDevReleaseNotes != null &&
              cached!.resolvedDevReleaseNotes!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 8),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '开发版更新说明',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Colors.orange.shade700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      ReleaseNotesTranslator.translate(
                              cached.resolvedDevReleaseNotes) ??
                          cached.resolvedDevReleaseNotes!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
        ],
        // 每夜版/持续构建
        if (emulator.nightlyUrl.isNotEmpty) ...[
          _DownloadChannelCard(
            icon: Icons.nightlight,
            label: '每夜版（自动构建）',
            description: '每日自动构建，功能最前沿',
            url: emulator.nightlyUrl,
            color: Colors.deepPurple,
          ),
          const SizedBox(height: 8),
        ],
        // GitHub Releases 页面（通用回退）
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: () => _launchDownload(context, emulator),
            icon: Icon(_sourceIcon(emulator.sourceType)),
            label: Text(_downloadButtonLabel(emulator.sourceType)),
          ),
        ),
        if (emulator.website.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _launchUrl(context, emulator.website),
              icon: const Icon(Icons.language),
              label: const Text('访问官网'),
            ),
          ),
        ],
      ],
    );
  }

  /// 收藏按钮。
  Widget _buildFavoriteButton(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<bool> isFavAsync,
    String consoleId,
  ) {
    final isFav = isFavAsync.valueOrNull ?? false;
    return SizedBox(
      width: double.infinity,
      child: isFav
          ? OutlinedButton.icon(
              onPressed: () => _toggleFavorite(ref, consoleId, isFav),
              icon: const Icon(Icons.favorite, color: Colors.red),
              label: const Text('已收藏，点击取消'),
            )
          : FilledButton.tonalIcon(
              onPressed: () => _toggleFavorite(ref, consoleId, isFav),
              icon: const Icon(Icons.favorite_border),
              label: const Text('收藏'),
            ),
    );
  }

  /// 切换收藏状态。
  Future<void> _toggleFavorite(
    WidgetRef ref,
    String consoleId,
    bool isFav,
  ) async {
    final db = ref.read(appDatabaseProvider);
    if (isFav) {
      await db.favoritesDao.removeFavorite(emulatorId);
    } else {
      await db.favoritesDao.addFavorite(
        emulatorId: emulatorId,
        consoleId: consoleId,
      );
    }
  }

  /// 打开下载源。
  Future<void> _launchDownload(BuildContext context, Emulator emulator) async {
    String url;
    switch (emulator.sourceType) {
      case 'github':
        // GitHub Releases 页面
        url = emulator.sourceUrl.endsWith('/')
            ? '${emulator.sourceUrl}releases'
            : '${emulator.sourceUrl}/releases';
        if (emulator.sourceUrl.isEmpty) return;
        break;
      case 'playstore':
        if (emulator.playStoreId.isEmpty) return;
        url = 'https://play.google.com/store/apps/details?id=${emulator.playStoreId}';
        break;
      case 'website':
        if (emulator.website.isEmpty && emulator.sourceUrl.isEmpty) return;
        url = emulator.website.isNotEmpty ? emulator.website : emulator.sourceUrl;
        break;
      default:
        return;
    }
    await _launchUrl(context, url);
  }

  /// 使用 url_launcher 打开链接。
  Future<void> _launchUrl(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开链接：$url')),
      );
    }
  }

  IconData _sourceIcon(String sourceType) {
    switch (sourceType) {
      case 'github':
        return Icons.code;
      case 'gitlab':
        return Icons.code;
      case 'playstore':
        return Icons.shop;
      case 'website':
        return Icons.language;
      default:
        return Icons.download;
    }
  }

  String _downloadButtonLabel(String sourceType) {
    switch (sourceType) {
      case 'github':
        return 'GitHub Releases';
      case 'gitlab':
        return 'GitLab Releases';
      case 'playstore':
        return 'Google Play 下载';
      case 'website':
        return '官网下载';
      default:
        return '下载';
    }
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
          Text('未找到该模拟器', style: theme.textTheme.bodyLarge),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => context.pop(),
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }
}

/// 信息胶囊标签。
class _InfoPill extends StatelessWidget {
  const _InfoPill({
    required this.icon,
    required this.label,
    this.color,
  });

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fg = color ?? cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.componentRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 4),
          Text(label, style: theme.textTheme.labelSmall?.copyWith(
            color: fg, fontWeight: FontWeight.w600,
          )),
        ],
      ),
    );
  }
}

/// 兼容性标签。
class _CompatibilityTag extends StatelessWidget {
  const _CompatibilityTag({required this.level});

  final String level;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = AppTheme.compatibilityColor(level);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(AppTheme.componentRadius),
      ),
      child: Text(
        AppTheme.compatibilityLabel(level),
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 属性列表项。
class _AttributeTile extends StatelessWidget {
  const _AttributeTile({
    required this.icon,
    required this.title,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Text(title, style: theme.textTheme.bodyMedium),
          const Spacer(),
          trailing,
        ],
      ),
    );
  }
}

/// 下载渠道卡片：稳定版/开发版/每夜版。
class _DownloadChannelCard extends StatelessWidget {
  const _DownloadChannelCard({
    required this.icon,
    required this.label,
    required this.description,
    required this.url,
    required this.color,
    this.isPrimary = false,
  });

  final IconData icon;
  final String label;
  final String description;
  final String url;
  final Color color;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: isPrimary ? color.withOpacity(0.08) : cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppTheme.componentRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          final uri = Uri.parse(url);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          } else if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('无法打开链接：$url')),
            );
          }
        },
        borderRadius: BorderRadius.circular(AppTheme.componentRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isPrimary ? color : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
