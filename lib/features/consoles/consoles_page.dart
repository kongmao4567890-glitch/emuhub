import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/database.dart';
import '../../data/models/console.dart';
import '../../data/models/emulator.dart';
import '../../providers.dart';
import '../../widgets/version_badge.dart';

/// 监听全部版本缓存（文件私有）。
final _cachedVersionsStreamProvider =
    StreamProvider<List<CachedVersion>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.cachedVersionsDao.watchAllCachedVersions();
});

/// 厂商 id -> 显示名。
String vendorDisplayName(String vendor) {
  switch (vendor) {
    case 'nintendo':
      return '任天堂';
    case 'sony':
      return '索尼';
    case 'sega':
      return '世嘉';
    case 'atari':
      return 'Atari';
    case 'microsoft':
    case 'microsoft_ascii':
      return '微软';
    case 'snk':
      return 'SNK';
    case 'nec':
      return 'NEC';
    case 'bandai':
      return '万代';
    case 'commodore':
      return 'Commodore';
    case 'panasonic':
      return '松下';
    case 'coleco':
      return 'Coleco';
    case 'mattel':
      return 'Mattel';
    case 'gce':
      return 'GCE';
    case 'libretro':
      return 'Libretro';
    case 'apple':
      return 'Apple';
    case 'philips':
      return '飞利浦';
    case 'sharp':
      return '夏普';
    case 'sinclair':
      return 'Sinclair';
    case 'amstrad':
      return 'Amstrad';
    case 'fujitsu':
      return '富士通';
    case 'vtech':
      return 'VTech';
    case 'epoch':
      return 'Epoch';
    case 'casio':
      return '卡西欧';
    case 'pioneer':
      return 'Pioneer';
    case 'tandy':
      return 'Tandy';
    case 'acorn':
      return 'Acorn';
    case 'bally':
      return 'Bally';
    case 'apf':
      return 'APF';
    case 'entex':
      return 'Entex';
    case 'tiger':
      return 'Tiger';
    case 'cybiko':
      return 'Cybiko';
    case 'leapfrog':
      return 'LeapFrog';
    case 'nokia':
      return 'Nokia';
    case 'palm':
      return 'Palm';
    case 'adobe':
      return 'Adobe';
    case 'oracle':
      return 'Oracle';
    case 'electronika':
      return 'Electronika';
    case 'emerson':
      return 'Emerson';
    case 'fairchild':
      return 'Fairchild';
    case 'various':
      return '其他';
    default:
      return vendor; // 显示原始厂商名
  }
}

/// 厂商筛选选项：(vendorKey, 显示名)。
const List<({String key, String label})> _vendorFilters = [
  (key: 'all', label: '全部'),
  (key: 'nintendo', label: '任天堂'),
  (key: 'sony', label: '索尼'),
  (key: 'sega', label: '世嘉'),
  (key: 'atari', label: 'Atari'),
  (key: 'microsoft', label: '微软'),
  (key: 'snk', label: 'SNK'),
  (key: 'nec', label: 'NEC'),
  (key: 'commodore', label: 'Commodore'),
  (key: 'bandai', label: '万代'),
  (key: 'apple', label: 'Apple'),
  (key: 'vtech', label: 'VTech'),
  (key: 'epoch', label: 'Epoch'),
  (key: 'fujitsu', label: '富士通'),
  (key: 'sharp', label: '夏普'),
  (key: 'philips', label: '飞利浦'),
  (key: 'mattel', label: 'Mattel'),
  (key: 'casio', label: '卡西欧'),
  (key: 'amstrad', label: 'Amstrad'),
  (key: 'various', label: '其他'),
];

/// 机种库页面（核心浏览页）。
///
/// 提供搜索栏、厂商筛选 Chips 与 2 列 GridView 卡片。
class ConsolesPage extends ConsumerStatefulWidget {
  const ConsolesPage({super.key});

  @override
  ConsumerState<ConsolesPage> createState() => _ConsolesPageState();
}

class _ConsolesPageState extends ConsumerState<ConsolesPage> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _selectedVendor = 'all';
  String _selectedPlatform = 'all';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 根据搜索词与厂商筛选过滤机种列表。
  List<Console> _filterConsoles(List<Console> consoles) {
    // 有独立筛选 Chip 的厂商 key 集合
    const knownVendors = {
      'nintendo', 'sony', 'sega', 'atari', 'microsoft', 'microsoft_ascii',
      'snk', 'nec', 'commodore', 'bandai',
      'apple', 'vtech', 'epoch', 'fujitsu', 'sharp',
      'philips', 'mattel', 'casio', 'amstrad',
    };
    return consoles.where((console) {
      final platformEmulators = _selectedPlatform == 'all'
          ? console.emulators
          : console.emulators
              .where((e) => e.supportsPlatform(_selectedPlatform))
              .toList();
      if (platformEmulators.isEmpty) return false;

      // 厂商筛选
      if (_selectedVendor == 'various') {
        // "其他" 显示不在已知列表中的厂商
        if (knownVendors.contains(console.vendor)) return false;
      } else if (_selectedVendor == 'microsoft') {
        // 微软筛选同时匹配 microsoft 和 microsoft_ascii
        if (console.vendor != 'microsoft' &&
            console.vendor != 'microsoft_ascii') {
          return false;
        }
      } else if (_selectedVendor != 'all' &&
          console.vendor != _selectedVendor) {
        return false;
      }
      // 搜索筛选：匹配机种名或模拟器名
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        final nameMatch = console.name.toLowerCase().contains(query);
        final emulatorMatch = platformEmulators
            .any((e) => e.name.toLowerCase().contains(query));
        if (!nameMatch && !emulatorMatch) return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(emulatorsConfigProvider);
    final cachedVersionsAsync = ref.watch(_cachedVersionsStreamProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('机种库')),
      body: configAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => _buildError(error),
        data: (config) {
          final filtered = _filterConsoles(config.consoles);
          return Column(
            children: [
              // 搜索栏
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: '搜索机种或模拟器',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    isDense: true,
                  ),
                  onChanged: (value) =>
                      setState(() => _searchQuery = value.trim()),
                ),
              ),
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (final option in const [
                      (key: 'all', label: '全部平台'),
                      (key: 'android', label: 'Android'),
                      (key: 'windows', label: 'Windows'),
                      (key: 'linux', label: 'Linux'),
                      (key: 'macos', label: 'macOS'),
                    ]) ...[
                      ChoiceChip(
                        avatar: Icon(
                          option.key == 'android'
                              ? Icons.android
                              : option.key == 'all'
                                  ? Icons.devices
                                  : Icons.desktop_windows,
                          size: 16,
                        ),
                        label: Text(option.label),
                        selected: _selectedPlatform == option.key,
                        onSelected: (_) => setState(
                          () => _selectedPlatform = option.key,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
              // 厂商筛选 Chips
              SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _vendorFilters.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final filter = _vendorFilters[index];
                    final selected = _selectedVendor == filter.key;
                    return FilterChip(
                      label: Text(filter.label),
                      selected: selected,
                      onSelected: (_) =>
                          setState(() => _selectedVendor = filter.key),
                    );
                  },
                ),
              ),
              const SizedBox(height: 4),
              // GridView
              Expanded(
                child: filtered.isEmpty
                    ? _buildEmptyResult()
                    : cachedVersionsAsync.when(
                        loading: () => GridView.builder(
                          padding: const EdgeInsets.all(16),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 0.88,
                          ),
                          itemCount: filtered.length,
                          itemBuilder: (_, __) => const Card(
                            child: Center(
                              child: CircularProgressIndicator(),
                            ),
                          ),
                        ),
                        // 版本缓存只是徽标辅助数据，读取失败不应吞掉机种列表，
                        // 按空缓存正常渲染网格
                        error: (_, __) => GridView.builder(
                          padding: const EdgeInsets.all(16),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 0.88,
                          ),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            return _ConsoleCard(
                              console: filtered[index],
                              cachedVersions: const [],
                              platform: _selectedPlatform,
                            );
                          },
                        ),
                        data: (cached) => GridView.builder(
                          padding: const EdgeInsets.all(16),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 0.88,
                          ),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            return _ConsoleCard(
                              console: filtered[index],
                              cachedVersions: cached,
                              platform: _selectedPlatform,
                            );
                          },
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
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
              onPressed: () =>
                  ref.invalidate(emulatorsConfigProvider),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyResult() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off,
              size: 48, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            '未找到匹配的机种',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 机种卡片。
class _ConsoleCard extends StatelessWidget {
  const _ConsoleCard({
    required this.console,
    required this.cachedVersions,
    required this.platform,
  });

  final Console console;
  final List<CachedVersion> cachedVersions;
  final String platform;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    // 查找该机种下所有模拟器的缓存版本
    final visibleEmulators = platform == 'all'
        ? console.emulators
        : console.emulators
            .where((emulator) => emulator.supportsPlatform(platform))
            .toList();
    final emulatorIds = visibleEmulators.map((e) => e.id).toSet();
    final relevant =
        cachedVersions.where((c) => emulatorIds.contains(c.emulatorId)).toList();
    final hasNewVersion = relevant.any((c) => c.isNew);
    // 取最近检查的一条作为 "最新版本号"
    final latest = relevant.isNotEmpty
        ? (relevant..sort(
            (a, b) => b.lastCheckedAt.compareTo(a.lastCheckedAt))).first
        : null;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/console/${console.id}'),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 机种真实图片
                SizedBox(
                  width: double.infinity,
                  height: 88,
                  child: console.imagePath.isNotEmpty
                      ? Hero(
                          tag: 'console-image-${console.id}',
                          child: Image.asset(
                            console.imagePath,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _buildEmojiFallback(
                                cs, console.icon),
                          ),
                        )
                      : _buildEmojiFallback(cs, console.icon),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 机种名
                      Text(
                        console.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      // 厂商 + 年份
                      Text(
                        '${vendorDisplayName(console.vendor)} · ${console.year}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      // 模拟器数量
                      Row(
                        children: [
                          Icon(Icons.apps, size: 14,
                              color: cs.onSurfaceVariant),
                          const SizedBox(width: 4),
                          Text(
                            '${visibleEmulators.length} 个模拟器',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // 最新版本号
                      if (latest != null && latest.currentVersion.isNotEmpty)
                        VersionTag(version: latest.currentVersion)
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
              ],
            ),
            // 新版徽标
            if (hasNewVersion)
              Positioned(
                top: 8,
                right: 8,
                child: const NewVersionBadge(),
              ),
          ],
        ),
      ),
    );
  }

  /// 图片加载失败或无图片时，回退显示 emoji。
  Widget _buildEmojiFallback(ColorScheme cs, String icon) {
    return Container(
      color: cs.primaryContainer,
      alignment: Alignment.center,
      child: Text(icon, style: const TextStyle(fontSize: 36)),
    );
  }
}
