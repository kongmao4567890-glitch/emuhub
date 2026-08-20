/// One translated emulator-news article prepared by GitHub Actions.
class NewsArticle {
  const NewsArticle({
    required this.id,
    required this.title,
    required this.originalTitle,
    required this.category,
    required this.categoryLabel,
    required this.kind,
    required this.publishedAt,
    required this.sourceName,
    required this.sourceUrl,
    required this.imageUrl,
    required this.officialUrl,
    required this.summary,
    required this.content,
    required this.originalContent,
    required this.platforms,
    required this.relatedEmulatorIds,
  });

  final String id;
  final String title;
  final String originalTitle;
  final String category;
  final String categoryLabel;
  final String kind;
  final DateTime publishedAt;
  final String sourceName;
  final String sourceUrl;
  final String imageUrl;
  final String officialUrl;
  final String summary;
  final String content;
  final String originalContent;
  final List<String> platforms;
  final List<String> relatedEmulatorIds;

  factory NewsArticle.fromJson(Map<String, dynamic> json) {
    List<String> strings(dynamic value) => value is List
        ? value.map((item) => item.toString()).toList(growable: false)
        : const <String>[];

    return NewsArticle(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      originalTitle: json['originalTitle']?.toString() ?? '',
      category: json['category']?.toString() ?? 'other',
      categoryLabel: json['categoryLabel']?.toString() ?? '其他',
      kind: json['kind']?.toString() ?? 'emulator',
      publishedAt: DateTime.tryParse(json['publishedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      sourceName: json['sourceName']?.toString() ?? 'Emu-France',
      sourceUrl: json['sourceUrl']?.toString() ?? '',
      imageUrl: json['imageUrl']?.toString() ?? '',
      officialUrl: json['officialUrl']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      originalContent: json['originalContent']?.toString() ?? '',
      platforms: strings(json['platforms']),
      relatedEmulatorIds: strings(json['relatedEmulatorIds']),
    );
  }

  bool get isAndroid => platforms.contains('android');
  bool get isPc => platforms.contains('pc');
}

class NewsFeed {
  const NewsFeed({
    required this.generatedAt,
    required this.retentionDays,
    required this.articles,
  });

  final DateTime generatedAt;
  final int retentionDays;
  final List<NewsArticle> articles;

  factory NewsFeed.fromJson(Map<String, dynamic> json) {
    final rawArticles = json['articles'];
    final articles = rawArticles is List
        ? rawArticles
            .whereType<Map>()
            .map((item) => NewsArticle.fromJson(Map<String, dynamic>.from(item)))
            .where((item) => item.id.isNotEmpty && item.content.isNotEmpty)
            .toList(growable: false)
        : const <NewsArticle>[];
    return NewsFeed(
      generatedAt: DateTime.tryParse(json['generatedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      retentionDays: int.tryParse(json['retentionDays']?.toString() ?? '') ?? 90,
      articles: articles,
    );
  }
}
