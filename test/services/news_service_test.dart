import 'package:flutter_test/flutter_test.dart';

import 'package:emuhub/services/news/news_service.dart';

void main() {
  test('loads translated articles once and parses filter metadata', () async {
    var loads = 0;
    final service = NewsService(
      loader: () async {
        loads++;
        return <String, dynamic>{
          'generatedAt': '2026-08-19T23:00:00Z',
          'retentionDays': 90,
          'articles': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': '136089',
              'title': '【家用机】Flycast v2.7',
              'originalTitle': '[Consoles de salon] Flycast v2.7',
              'category': 'home_console',
              'categoryLabel': '家用机',
              'kind': 'emulator',
              'publishedAt': '2026-08-19T16:33:00Z',
              'sourceName': 'Emu-France',
              'sourceUrl': 'https://www.emu-france.com/news/136089-example/',
              'imageUrl': 'https://example.com/flycast.png',
              'officialUrl': 'https://github.com/flyinghead/flycast',
              'summary': '中文摘要',
              'content': '完整中文正文',
              'originalContent': 'Texte français',
              'platforms': <String>['android', 'pc'],
              'relatedEmulatorIds': <String>['flycast'],
            },
          ],
        };
      },
    );

    final first = await service.load();
    final second = await service.load();
    final article = first.articles.single;

    expect(article.title, '【家用机】Flycast v2.7');
    expect(article.content, '完整中文正文');
    expect(article.isAndroid, isTrue);
    expect(article.isPc, isTrue);
    expect(article.relatedEmulatorIds, <String>['flycast']);
    expect(second.articles.single.id, '136089');
    expect(loads, 1);
  });
}
