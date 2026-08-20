import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/news_article.dart';
import '../../providers.dart';
import 'news_widgets.dart';

final _favoriteEmulatorIdsProvider = StreamProvider<Set<String>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.favoritesDao.watchAllFavorites().map(
        (items) => items.map((item) => item.emulatorId).toSet(),
      );
});

enum _NewsFilter { all, android, pc, emulator, tool, driver, favorites }

class NewsPage extends ConsumerStatefulWidget {
  const NewsPage({super.key});

  @override
  ConsumerState<NewsPage> createState() => _NewsPageState();
}

class _NewsPageState extends ConsumerState<NewsPage> {
  _NewsFilter _filter = _NewsFilter.all;

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(newsFeedProvider);
    final favorites = ref.watch(_favoriteEmulatorIdsProvider).valueOrNull ??
        const <String>{};
    return Scaffold(
      appBar: AppBar(title: const Text('模拟器资讯')),
      body: feedAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorState(
          message: error.toString(),
          onRetry: () {
            ref.invalidate(newsServiceProvider);
            ref.invalidate(newsFeedProvider);
          },
        ),
        data: (feed) {
          final articles = feed.articles
              .where((article) => _matches(article, favorites))
              .toList(growable: false);
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(newsServiceProvider);
              ref.invalidate(newsFeedProvider);
              await ref.read(newsFeedProvider.future);
            },
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 58,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      children: [
                        _chip(_NewsFilter.all, '全部'),
                        _chip(_NewsFilter.android, 'Android'),
                        _chip(_NewsFilter.pc, 'PC'),
                        _chip(_NewsFilter.emulator, '模拟器'),
                        _chip(_NewsFilter.tool, '工具'),
                        _chip(_NewsFilter.driver, '驱动'),
                        _chip(_NewsFilter.favorites, '我的收藏'),
                      ],
                    ),
                  ),
                ),
                if (articles.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: Text('当前筛选下暂无资讯')),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    sliver: SliverList.separated(
                      itemCount: articles.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) =>
                          NewsArticleCard(article: articles[index]),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _chip(_NewsFilter value, String label) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        selected: _filter == value,
        label: Text(label),
        onSelected: (_) => setState(() => _filter = value),
      ),
    );
  }

  bool _matches(NewsArticle article, Set<String> favorites) {
    switch (_filter) {
      case _NewsFilter.all:
        return true;
      case _NewsFilter.android:
        return article.isAndroid;
      case _NewsFilter.pc:
        return article.isPc;
      case _NewsFilter.emulator:
        return article.kind == 'emulator';
      case _NewsFilter.tool:
        return article.kind == 'tool';
      case _NewsFilter.driver:
        return article.kind == 'driver';
      case _NewsFilter.favorites:
        return article.relatedEmulatorIds.any(favorites.contains);
    }
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 44),
            const SizedBox(height: 12),
            const Text('新闻加载失败'),
            const SizedBox(height: 6),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
