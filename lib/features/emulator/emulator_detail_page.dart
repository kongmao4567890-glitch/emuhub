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
import '../../services/update/google_translate_service.dart';
import '../../services/update/mymemory_translate_service.dart';
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
    case 'forgejo':
      return 'Forgejo';
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
/// 页面只展示检查更新时写入的缓存，不会因进入页面而发起网络请求；
/// 用户仍可通过刷新按钮单独重新检查当前模拟器。
class EmulatorDetailPage extends ConsumerStatefulWidget {
  const EmulatorDetailPage({super.key, required this.emulatorId});

  final String emulatorId;

  @override
  ConsumerState<EmulatorDetailPage> createState() => _EmulatorDetailPageState();
}

class _EmulatorDetailPageState extends ConsumerState<EmulatorDetailPage> {
  bool _hasMarkedAsSeen = false;
  bool _isChecking = false;

  /// 手动触发版本检查（点击刷新按钮时调用）。
  Future<void> _manualCheckUpdate() async {
    if (_isChecking) return;
    final config = ref.read(emulatorsConfigProvider).valueOrNull;
    if (config == null) return;
    final result = findEmulator(config.consoles, widget.emulatorId);
    if (result == null) return;

    setState(() => _isChecking = true);
    try {
      final updateService = ref.read(updateServiceProvider);
      await updateService.checkOne(result.emulator);
      if (mounted) {
        await ref
            .read(appDatabaseProvider)
            .cachedVersionsDao
            .markAsSeen(widget.emulatorId);
      }
    } finally {
      if (mounted) {
        setState(() => _isChecking = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final configAsync = ref.watch(emulatorsConfigProvider);
    final cachedAsync = ref.watch(_cachedVersionProvider(widget.emulatorId));
    final isFavAsync = ref.watch(_isFavoriteProvider(widget.emulatorId));

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
        final result = findEmulator(config.consoles, widget.emulatorId);
        if (result == null) {
          return Scaffold(
            appBar: AppBar(),
            body: _buildNotFound(context),
          );
        }
        final console = result.console;
        final emulator = result.emulator;

        // 进入详情页只清除本地未读标记，不发起版本检查网络请求。
        if (!_hasMarkedAsSeen) {
          _hasMarkedAsSeen = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ref
                .read(appDatabaseProvider)
                .cachedVersionsDao
                .markAsSeen(widget.emulatorId);
          });
        }

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
                  error: (_, __) => const SizedBox.shrink(),
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
      },
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
      actions: [
        IconButton(
          icon: _isChecking
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          onPressed: _isChecking ? null : _manualCheckUpdate,
          tooltip: '检查更新',
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        title: Text(
          emulator.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        background: emulator.iconPath.isNotEmpty
            ? Hero(
                tag: 'emulator-icon-${emulator.id}',
                child: Container(
                  color: cs.surfaceContainerHighest,
                  child: Image.asset(
                    emulator.iconPath,
                    fit: BoxFit.contain,
                    alignment: Alignment.center,
                    errorBuilder: (_, __, ___) =>
                        _buildConsoleBg(console, cs),
                  ),
                ),
              )
            : _buildConsoleBg(console, cs),
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

  /// 机种图片或 emoji 回退背景。
  Widget _buildConsoleBg(Console console, ColorScheme cs) {
    if (console.imagePath.isNotEmpty) {
      return Image.asset(
        console.imagePath,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildGradientBg(cs, console.icon),
      );
    }
    return _buildGradientBg(cs, console.icon);
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
            if (emulator.sourceType != 'playstore' &&
                emulator.playStoreId.isNotEmpty)
              const _InfoPill(
                icon: Icons.shop,
                label: 'Google Play',
              ),
            _InfoPill(
              icon: emulator.supportsDesktop
                  ? Icons.desktop_windows
                  : Icons.android,
              label: emulator.platformLabel,
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
            child: cached == null
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
                      if (cached.currentVersion.isNotEmpty)
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
                        )
                      else
                        Row(
                          children: [
                            Icon(Icons.info_outline, color: cs.primary),
                            const SizedBox(width: 8),
                            Text(
                              'Google Play 未公开版本号',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
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
                        TranslatedReleaseNotes(
                          text: cached.releaseNotes!,
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

  /// 属性区域：兼容性、支持平台、系统要求、核心与开源状态。
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
                icon: Icons.devices,
                title: '支持平台',
                trailing: Text(
                  emulator.platformLabel,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (emulator.supportsPlatform('android')) ...[
                const Divider(height: 1, indent: 16),
                _AttributeTile(
                  icon: Icons.android,
                  title: '最低 Android 版本',
                  trailing: Text(
                    emulator.minAndroid.isEmpty ? '请查看官网' : emulator.minAndroid,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
              if (emulator.supportsDesktop) ...[
                const Divider(height: 1, indent: 16),
                _AttributeTile(
                  icon: Icons.desktop_windows,
                  title: 'PC 系统要求',
                  trailing: Text(
                    emulator.desktopRequirements.isEmpty
                        ? '请查看官网'
                        : emulator.desktopRequirements,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
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
                    TranslatedReleaseNotes(
                      text: cached.resolvedDevReleaseNotes!,
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
        // 官方下载页（没有有效商店包名时不渲染失效按钮）。
        if (_hasDownloadSource(emulator))
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: () => _launchDownload(context, emulator),
              icon: Icon(_sourceIcon(emulator.sourceType)),
              label: Text(_downloadButtonLabel(emulator.sourceType)),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '暂无可用的官方下载源',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        // 部分开源项目同时提供 Google Play 正式版。它是独立下载渠道，
        // 不应因为版本检查来源是 GitHub/官网而被隐藏。
        if (emulator.sourceType != 'playstore' &&
            emulator.playStoreId.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _launchPlayStore(context, emulator),
              icon: const Icon(Icons.shop),
              label: const Text('Google Play 下载'),
            ),
          ),
        ],
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
      await db.favoritesDao.removeFavorite(widget.emulatorId);
    } else {
      await db.favoritesDao.addFavorite(
        emulatorId: widget.emulatorId,
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
      case 'gitlab':
        if (emulator.sourceUrl.isEmpty) return;
        url = emulator.sourceUrl.endsWith('/')
            ? '${emulator.sourceUrl}-/releases'
            : '${emulator.sourceUrl}/-/releases';
        break;
      case 'forgejo':
        // Forgejo Releases 页面
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

  /// 打开已验证包名对应的 Google Play 页面。
  Future<void> _launchPlayStore(
    BuildContext context,
    Emulator emulator,
  ) async {
    if (emulator.playStoreId.isEmpty) return;
    await _launchUrl(
      context,
      'https://play.google.com/store/apps/details?id=${emulator.playStoreId}',
    );
  }

  bool _hasDownloadSource(Emulator emulator) {
    switch (emulator.sourceType) {
      case 'github':
      case 'gitlab':
      case 'forgejo':
        return emulator.sourceUrl.isNotEmpty;
      case 'playstore':
        return emulator.playStoreId.isNotEmpty;
      case 'website':
        return emulator.website.isNotEmpty || emulator.sourceUrl.isNotEmpty;
      default:
        return false;
    }
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
      case 'forgejo':
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
      case 'forgejo':
        return 'Forgejo Releases';
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

/// 异步翻译的更新说明组件。
///
/// 显示流程：
/// 1. 先用字典翻译（ReleaseNotesTranslator）即时显示
/// 2. 后台调用 Google 翻译获取更完整的中文翻译
/// 3. Google 翻译成功后替换为翻译结果
/// 4. Google 翻译失败则保留字典翻译结果
///
/// 如果文本已经是中文（中文占比高），直接显示原文。
class TranslatedReleaseNotes extends StatefulWidget {
  const TranslatedReleaseNotes({
    super.key,
    required this.text,
    this.style,
  });

  final String text;
  final TextStyle? style;

  @override
  State<TranslatedReleaseNotes> createState() => _TranslatedReleaseNotesState();
}

class _TranslatedReleaseNotesState extends State<TranslatedReleaseNotes> {
  String? _translatedText;
  bool _isTranslating = true;
  /// 翻译来源：'google' | 'mymemory' | 'dict'
  String _source = 'dict';
  bool _showOriginal = false;

  @override
  void initState() {
    super.initState();
    _translate();
  }

  @override
  void didUpdateWidget(covariant TranslatedReleaseNotes oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 文本变化（如后台检查写入了新的 releaseNotes）时重新翻译，
    // 否则会一直显示旧文本的翻译结果
    if (oldWidget.text != widget.text) {
      setState(() {
        _translatedText = null;
        _isTranslating = true;
        _source = 'dict';
        _showOriginal = false;
      });
      _translate();
    }
  }

  Future<void> _translate() async {
    // 如果文本主要是中文，不需要翻译
    if (!GoogleTranslateService.needsTranslation(widget.text)) {
      if (mounted) {
        setState(() {
          _translatedText = widget.text;
          _isTranslating = false;
          _source = 'google';
        });
      }
      return;
    }

    // 先用字典翻译作为即时回退（立即可用）
    final dictResult = ReleaseNotesTranslator.translate(widget.text) ?? widget.text;

    // 尝试 1: Google 翻译（国际用户首选，但中国大陆不可用）
    final googleResult = await GoogleTranslateService.translateToChinese(widget.text);

    if (googleResult != null && googleResult.isNotEmpty) {
      if (mounted) {
        setState(() {
          _translatedText = googleResult;
          _isTranslating = false;
          _source = 'google';
        });
      }
      return;
    }

    // 尝试 2: MyMemory 翻译（Google 不可用时的备选，中国大陆可访问）
    final myMemoryResult = await MyMemoryTranslateService.translateToChinese(widget.text);

    if (myMemoryResult != null && myMemoryResult.isNotEmpty) {
      if (mounted) {
        setState(() {
          _translatedText = myMemoryResult;
          _isTranslating = false;
          _source = 'mymemory';
        });
      }
      return;
    }

    // 尝试 3: 字典翻译（离线，始终可用）
    if (mounted) {
      setState(() {
        _translatedText = dictResult;
        _isTranslating = false;
        _source = 'dict';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 查看原文模式
    if (_showOriginal) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.text, style: widget.style),
          const SizedBox(height: 4),
          _buildSourceChip('原文'),
        ],
      );
    }

    if (_isTranslating) {
      // 翻译中：先显示字典翻译结果（即时可用）
      final dictResult = ReleaseNotesTranslator.translate(widget.text) ?? widget.text;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(dictResult, style: widget.style),
          const SizedBox(height: 4),
          Row(
            children: [
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
              const SizedBox(width: 6),
              Text(
                '正在翻译...',
                style: (widget.style ?? const TextStyle()).copyWith(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_translatedText ?? widget.text, style: widget.style),
        const SizedBox(height: 4),
        Row(
          children: [
            _buildSourceChip(
              switch (_source) {
                'google' => 'Google 翻译',
                'mymemory' => 'MyMemory 翻译',
                _ => '字典翻译',
              },
            ),
            const SizedBox(width: 8),
          ],
        ),
      ],
    );
  }

  /// 构建翻译来源标签 + 原文切换按钮。
  Widget _buildSourceChip(String label) {
    // google/mymemory 为在线翻译（绿色），dict 为离线字典（橙色）
    final isOnline = _source == 'google' || _source == 'mymemory';
    return InkWell(
      onTap: () {
        setState(() {
          _showOriginal = !_showOriginal;
        });
      },
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: isOnline ? Colors.green : Colors.orange,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              _showOriginal ? Icons.translate : Icons.code,
              size: 12,
              color: Colors.grey,
            ),
          ],
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
          const SizedBox(width: 12),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: trailing,
            ),
          ),
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
