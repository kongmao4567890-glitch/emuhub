import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/news_article.dart';
import '../../providers.dart';
import '../emulator/emulator_detail_page.dart' show findEmulator;
import 'news_widgets.dart';

class NewsDetailPage extends ConsumerStatefulWidget {
  const NewsDetailPage({super.key, required this.articleId});

  final String articleId;

  @override
  ConsumerState<NewsDetailPage> createState() => _NewsDetailPageState();
}

class _NewsDetailPageState extends ConsumerState<NewsDetailPage> {
  bool _showOriginal = false;

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(newsFeedProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('资讯详情'),
        actions: [
          IconButton(
            tooltip: '打开原文',
            icon: const Icon(Icons.open_in_new),
            onPressed: feedAsync.valueOrNull == null
                ? null
                : () {
                    final article = _find(feedAsync.valueOrNull!.articles);
                    if (article != null) _open(article.sourceUrl);
                  },
          ),
        ],
      ),
      body: feedAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('新闻加载失败：$error')),
        data: (feed) {
          final article = _find(feed.articles);
          if (article == null) {
            return const Center(child: Text('这条新闻已不在 90 天保留范围内'));
          }
          return _body(article);
        },
      ),
    );
  }

  NewsArticle? _find(List<NewsArticle> articles) {
    for (final article in articles) {
      if (article.id == widget.articleId) return article;
    }
    return null;
  }

  Widget _body(NewsArticle article) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final date = DateFormat('yyyy年MM月dd日 HH:mm')
        .format(article.publishedAt.toLocal());
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: NewsNetworkImage(url: article.imageUrl),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(label: Text(article.categoryLabel)),
                    Chip(
                      label: Text(
                        article.kind == 'tool'
                            ? '工具'
                            : article.kind == 'driver'
                                ? '驱动'
                                : '模拟器',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  article.title,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '${article.sourceName} · $date',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 18),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('中文')),
                    ButtonSegment(value: true, label: Text('原文')),
                  ],
                  selected: {_showOriginal},
                  onSelectionChanged: (value) =>
                      setState(() => _showOriginal = value.first),
                ),
                const SizedBox(height: 22),
                SelectableText(
                  _showOriginal ? article.originalContent : article.content,
                  style: theme.textTheme.bodyLarge?.copyWith(height: 1.75),
                ),
                const SizedBox(height: 24),
                _related(article),
                const SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(AppTheme.cardRadius),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '来源说明',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text('正文由 EmuHub 自动翻译整理，版本号、项目名称和下载信息请以原文与官网为准。'),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => _open(article.sourceUrl),
                            icon: const Icon(Icons.article_outlined),
                            label: const Text('查看原文'),
                          ),
                          if (article.officialUrl.isNotEmpty)
                            OutlinedButton.icon(
                              onPressed: () => _open(article.officialUrl),
                              icon: const Icon(Icons.language),
                              label: const Text('项目官网'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _related(NewsArticle article) {
    if (article.relatedEmulatorIds.isEmpty) return const SizedBox.shrink();
    final config = ref.watch(emulatorsConfigProvider).valueOrNull;
    if (config == null) return const SizedBox.shrink();
    final matches = <({String id, String name})>[];
    for (final id in article.relatedEmulatorIds) {
      final result = findEmulator(config.consoles, id);
      if (result != null) {
        matches.add((id: result.emulator.id, name: result.emulator.name));
      }
    }
    if (matches.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '相关模拟器',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: matches
              .map(
                (match) => ActionChip(
                  avatar: const Icon(Icons.sports_esports, size: 18),
                  label: Text(match.name),
                  onPressed: () => context.push('/emulator/${match.id}'),
                ),
              )
              .toList(),
        ),
      ],
    );
  }

  Future<void> _open(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开链接')),
        );
      }
    }
  }
}
