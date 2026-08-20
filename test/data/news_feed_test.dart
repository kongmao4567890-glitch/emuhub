import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:emuhub/data/models/news_article.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled Chinese news feed is complete and uniquely keyed', () async {
    final raw = await rootBundle.loadString('assets/news.json');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final feed = NewsFeed.fromJson(decoded);

    expect(decoded['schemaVersion'], 1);
    expect(feed.retentionDays, 90);
    expect(feed.articles.length, greaterThanOrEqualTo(5));
    expect(
      feed.articles.map((article) => article.id).toSet().length,
      feed.articles.length,
    );
    for (final article in feed.articles) {
      expect(article.title, startsWith('【'), reason: article.id);
      expect(article.content, isNotEmpty, reason: article.id);
      expect(article.originalContent, isNotEmpty, reason: article.id);
      expect(article.sourceUrl, startsWith('https://www.emu-france.com/news/'));
    }
  });
}
