import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_theme.dart';
import '../../data/database/database.dart';
import '../../data/models/console.dart';
import '../../data/models/emulators_config.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers.dart';
import '../../widgets/version_badge.dart';
import '../consoles/consoles_page.dart' show vendorDisplayName;
import '../emulator/emulator_detail_page.dart' show findEmulator;

/// 监听全部版本缓存（文件私有）。
final _cachedVersionsStreamProvider =
    StreamProvider<List<CachedVersion>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.cachedVersionsDao.watchAllCachedVersions();
});

/// 更新中心页面（核心）。
///
/// 展示有新版本的模拟器、已是最新的模拟器，以及手动检查更新入口。
class UpdateCenterPage extends ConsumerStatefulWidget {
  const UpdateCenterPage({super.key});

  @override
  ConsumerState<UpdateCenterPage> createState() => _UpdateCenterPageState();
}

class _UpdateCenterPageState extends ConsumerState<UpdateCenterPage> {
  bool _checking = false;
  String? _checkResultMessage;

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(emulatorsConfigProvider);
    final cachedAsync = ref.watch(_cachedVersionsStreamProvider);
    final settings = ref.watch(appSettingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('更新中心')),
      body: Column(
        children: [
          Expanded(
            child: configAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (error, stack) => _buildError(error),
              data: (config) {
                return cachedAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, __) => _buildError('缓存读取失败'),
                  data: (cached) => _buildBody(
                    context,
                    config.consoles,
                    cached,
                    settings,
                  ),
                );
              },
            ),
          ),
          // 底部检查按钮
          _buildCheckButton(context, configAsync),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    List<Console> consoles,
    List<CachedVersion> cached,
    AppSettings settings,
  ) {
    final hasUpdates = cached.where((c) => c.isNew).toList();
    final upToDate = cached.where((c) => !c.isNew).toList();

    // 计算上次检查时间（取所有缓存中最新的 lastCheckedAt）
    final lastChecked = cached.isNotEmpty
        ? cached
            .map((c) => c.lastCheckedAt)
            .reduce((a, b) => a > b ? a : b)
        : 0;
    final nextCheck = lastChecked > 0
        ? lastChecked + settings.checkIntervalDuration.inMilliseconds
        : 0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      children: [
        _StatusCard(
          updateCount: hasUpdates.length,
          lastCheckedAt: lastChecked,
          nextCheckAt: nextCheck,
        ),
        const SizedBox(height: 24),
        // 检测到更新
        if (hasUpdates.isNotEmpty) ...[
          _SectionTitle(
            icon: Icons.new_releases,
            iconColor: AppTheme.success,
            title: '检测到更新',
            count: hasUpdates.length,
          ),
          const SizedBox(height: 12),
          ...hasUpdates.map((c) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _UpdateCard(
                  cached: c,
                  consoles: consoles,
                ),
              )),
          const SizedBox(height: 8),
        ],
        // 已是最新（可折叠）
        if (upToDate.isNotEmpty)
          _UpToDateSection(
            cached: upToDate,
            consoles: consoles,
          ),
        if (hasUpdates.isEmpty && upToDate.isEmpty)
          _buildEmptyState(context),
        if (_checkResultMessage != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppTheme.componentRadius),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_checkResultMessage!,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// 底部 "立即检查更新" 按钮。
  Widget _buildCheckButton(
    BuildContext context,
    AsyncValue<EmulatorsConfig> configAsync,
  ) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: theme.colorScheme.outlineVariant,
              width: 0.5,
            ),
          ),
        ),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _checking ? null : () => _checkUpdates(configAsync),
            icon: _checking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.refresh),
            label: Text(_checking ? '正在检查...' : '立即检查更新'),
          ),
        ),
      ),
    );
  }

  /// 触发更新检查。
  Future<void> _checkUpdates(
    AsyncValue<EmulatorsConfig> configAsync,
  ) async {
    final config = configAsync.valueOrNull;
    if (config == null) return;

    setState(() {
      _checking = true;
      _checkResultMessage = null;
    });

    try {
      final allEmulators = config.consoles.expand((c) => c.emulators).toList();
      final updateService = ref.read(updateServiceProvider);
      final result = await updateService.checkAll(allEmulators);

      if (mounted) {
        setState(() {
          _checking = false;
          _checkResultMessage =
              '检查完成：共检查 ${result.checked} 个，发现 ${result.updated.length} 个新版本'
              '${result.failed.isNotEmpty ? '，${result.failed.length} 个失败' : ''}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _checking = false;
          _checkResultMessage = '检查失败：$e';
        });
      }
    }
  }

  Widget _buildError(Object error) {
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

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.check_circle_outline,
                size: 64, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('暂无更新数据', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '点击下方按钮检查更新',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部状态卡片：大数字 + 上次/下次检查时间。
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.updateCount,
    required this.lastCheckedAt,
    required this.nextCheckAt,
  });

  final int updateCount;
  final int lastCheckedAt;
  final int nextCheckAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dateFormat = DateFormat('MM-dd HH:mm');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
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
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$updateCount',
                style: theme.textTheme.displaySmall?.copyWith(
                  color: cs.onPrimary,
                  fontWeight: FontWeight.bold,
                  height: 1.0,
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '个模拟器有新版本',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: cs.onPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _TimeInfo(
                  icon: Icons.history,
                  label: '上次检查',
                  value: lastCheckedAt > 0
                      ? dateFormat.format(
                          DateTime.fromMillisecondsSinceEpoch(lastCheckedAt))
                      : '尚未检查',
                  onPrimary: cs.onPrimary,
                ),
              ),
              Container(
                width: 1,
                height: 32,
                color: cs.onPrimary.withOpacity(0.3),
              ),
              Expanded(
                child: _TimeInfo(
                  icon: Icons.schedule,
                  label: '下次检查',
                  value: nextCheckAt > 0
                      ? dateFormat.format(
                          DateTime.fromMillisecondsSinceEpoch(nextCheckAt))
                      : '待定',
                  onPrimary: cs.onPrimary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 状态卡片中的时间信息。
class _TimeInfo extends StatelessWidget {
  const _TimeInfo({
    required this.icon,
    required this.label,
    required this.value,
    required this.onPrimary,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color onPrimary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: onPrimary.withOpacity(0.8)),
        const SizedBox(width: 6),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: onPrimary.withOpacity(0.7),
                ),
              ),
              Text(
                value,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: onPrimary,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 分区标题。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.count,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 20),
        const SizedBox(width: 8),
        Text(title, style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
        )),
        if (count != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(AppTheme.componentRadius),
            ),
            child: Text(
              '$count',
              style: theme.textTheme.labelSmall?.copyWith(
                color: iconColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 更新卡片：每个有新版本的模拟器。
class _UpdateCard extends StatelessWidget {
  const _UpdateCard({required this.cached, required this.consoles});

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
        ? DateFormat('yyyy-MM-dd').format(
            DateTime.fromMillisecondsSinceEpoch(cached.lastReleaseDate!))
        : '未知';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            // 模拟器图标：优先显示模拟器官方图标，无图标时回退到机种 emoji
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(AppTheme.componentRadius),
              ),
              clipBehavior: Clip.antiAlias,
              alignment: Alignment.center,
              child: emulator != null && emulator.iconPath.isNotEmpty
                  ? Image.asset(
                      emulator.iconPath,
                      fit: BoxFit.cover,
                      width: 48,
                      height: 48,
                      errorBuilder: (_, __, ___) => Text(
                        console?.icon ?? '🎮',
                        style: const TextStyle(fontSize: 26),
                      ),
                    )
                  : Text(
                      console?.icon ?? '🎮',
                      style: const TextStyle(fontSize: 26),
                    ),
            ),
            const SizedBox(width: 12),
            // 中间信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    emulator?.name ?? cached.emulatorId,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    console != null
                        ? '${console.name} · ${vendorDisplayName(console.vendor)}'
                        : '未知机种',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      // 新版本号（绿色）
                      Icon(Icons.arrow_upward, size: 14,
                          color: AppTheme.success),
                      const SizedBox(width: 4),
                      Text(
                        cached.currentVersion,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: AppTheme.success,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 10),
                      // 发布时间
                      Icon(Icons.event, size: 12,
                          color: cs.onSurfaceVariant),
                      const SizedBox(width: 3),
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
            const SizedBox(width: 8),
            // 更新按钮
            FilledButton.tonal(
              onPressed: () =>
                  context.push('/emulator/${cached.emulatorId}'),
              child: const Text('更新'),
            ),
          ],
        ),
      ),
    );
  }
}

/// "已是最新" 可折叠分区。
class _UpToDateSection extends StatefulWidget {
  const _UpToDateSection({required this.cached, required this.consoles});

  final List<CachedVersion> cached;
  final List<Console> consoles;

  @override
  State<_UpToDateSection> createState() => _UpToDateSectionState();
}

class _UpToDateSectionState extends State<_UpToDateSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.check_circle,
          iconColor: theme.colorScheme.primary,
          title: '已是最新',
          count: widget.cached.length,
        ),
        const SizedBox(height: 8),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline,
                          color: theme.colorScheme.primary, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${widget.cached.length} 个模拟器已为最新版本',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      Icon(
                        _expanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
              if (_expanded)
                const Divider(height: 1),
              if (_expanded)
                ...widget.cached.map((c) {
                  final result =
                      findEmulator(widget.consoles, c.emulatorId);
                  final emulator = result?.emulator;
                  final console = result?.console;
                  return _UpToDateTile(
                    emulatorName: emulator?.name ?? c.emulatorId,
                    consoleName: console?.name ?? '未知机种',
                    emulatorIconPath: emulator?.iconPath ?? '',
                    consoleIcon: console?.icon ?? '🎮',
                    version: c.currentVersion,
                    onTap: () =>
                        context.push('/emulator/${c.emulatorId}'),
                  );
                }),
            ],
          ),
        ),
      ],
    );
  }
}

/// "已是最新" 列表项。
class _UpToDateTile extends StatelessWidget {
  const _UpToDateTile({
    required this.emulatorName,
    required this.consoleName,
    required this.emulatorIconPath,
    required this.consoleIcon,
    required this.version,
    required this.onTap,
  });

  final String emulatorName;
  final String consoleName;
  /// 模拟器官方图标路径（如 assets/emulators/xxx.png），为空时回退到机种 emoji。
  final String emulatorIconPath;
  /// 机种 emoji，仅在模拟器图标不可用时作为回退。
  final String consoleIcon;
  final String version;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // 模拟器图标：优先显示模拟器官方图标，无图标时回退到机种 emoji
            SizedBox(
              width: 28,
              height: 28,
              child: emulatorIconPath.isNotEmpty
                  ? Image.asset(
                      emulatorIconPath,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Text(
                        consoleIcon,
                        style: const TextStyle(fontSize: 20),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : Center(
                      child: Text(
                        consoleIcon,
                        style: const TextStyle(fontSize: 20),
                      ),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(emulatorName,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text(consoleName,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            VersionTag(version: version.isEmpty ? '未知' : version),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right,
                size: 18, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
