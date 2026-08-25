import 'dart:convert';

import 'package:dio/dio.dart';
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

  test('decodes the GitHub Contents API feed before raw fallback', () async {
    final payload = <String, dynamic>{
      'generatedAt': '2026-08-24T23:00:00Z',
      'retentionDays': 90,
      'articles': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'fresh',
          'title': '【Android更新】最新资讯',
          'originalTitle': 'Latest news',
          'category': 'android_update',
          'categoryLabel': 'Android更新',
          'kind': 'emulator',
          'publishedAt': '2026-08-24T22:30:00Z',
          'sourceName': 'EmuHub',
          'sourceUrl': 'https://example.com/news',
          'imageUrl': '',
          'officialUrl': 'https://example.com',
          'summary': '最新中文摘要',
          'content': '最新中文正文',
          'originalContent': 'Latest original content',
          'platforms': <String>['android'],
          'relatedEmulatorIds': <String>['fresh'],
        },
      ],
    };
    final dio = Dio();
    final requests = <String>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options.uri.toString());
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'encoding': 'base64',
                'content': base64Encode(utf8.encode(jsonEncode(payload))),
              },
            ),
          );
        },
      ),
    );
    final service = NewsService(
      dio: dio,
      contentsUrl: 'https://api.github.test/contents/news.json?ref=main',
      remoteUrl: 'https://raw.github.test/news.json',
    );

    final feed = await service.load(forceRefresh: true);

    expect(feed.articles.single.id, 'fresh');
    expect(requests, hasLength(1));
    expect(requests.single, startsWith('https://api.github.test/'));
    expect(requests.single, contains('&news='));
  });
}
