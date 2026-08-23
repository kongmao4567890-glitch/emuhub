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
      if (article.id.startsWith('android-release-')) {
        expect(article.isAndroid, isTrue, reason: article.id);
        expect(article.category, 'android_update', reason: article.id);
        expect(article.relatedEmulatorIds, isNotEmpty, reason: article.id);
        expect(
          article.content,
          contains('官方更新说明（中文）：'),
          reason: article.id,
        );
        expect(
          article.content,
          isNot(contains('官方更新说明（原文）：')),
          reason: article.id,
        );
      } else {
        expect(
          article.sourceUrl,
          startsWith('https://www.emu-france.com/news/'),
          reason: article.id,
        );
      }
    }
    expect(
      feed.articles.where((article) => article.isAndroid).length,
      greaterThanOrEqualTo(10),
    );
  });
}
