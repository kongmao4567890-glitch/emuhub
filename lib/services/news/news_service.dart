import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../../data/models/news_article.dart';

typedef NewsFeedLoader = Future<Map<String, dynamic>> Function();

/// Loads the cloud-translated news snapshot, with an APK-bundled fallback.
class NewsService {
  NewsService({
    Dio? dio,
    AssetBundle? bundle,
    NewsFeedLoader? loader,
    this.remoteUrl =
        'https://raw.githubusercontent.com/kongmao4567890-glitch/emuhub/main/data/news.json',
    this.contentsUrl =
        'https://api.github.com/repos/kongmao4567890-glitch/emuhub/contents/data/news.json?ref=main',
  })  : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 6),
                receiveTimeout: const Duration(seconds: 12),
                headers: const {
                  'Accept': 'application/json',
                  'User-Agent':
                      'EmuHub/1.0 (+https://github.com/kongmao4567890-glitch/emuhub)',
                },
              ),
            ),
        _bundle = bundle ?? rootBundle,
        _loader = loader;

  static const Duration _memoryTtl = Duration(minutes: 5);

  final Dio _dio;
  final AssetBundle _bundle;
  final NewsFeedLoader? _loader;
  final String remoteUrl;
  final String contentsUrl;
  Future<NewsFeed>? _inFlight;
  DateTime? _loadedAt;

  Future<NewsFeed> load({bool forceRefresh = false}) {
    final now = DateTime.now();
    if (!forceRefresh &&
        _inFlight != null &&
        _loadedAt != null &&
        now.difference(_loadedAt!) < _memoryTtl) {
      return _inFlight!;
    }
    _loadedAt = now;
    return _inFlight = _load();
  }

  Future<NewsFeed> _load() async {
    if (_loader != null) {
      return NewsFeed.fromJson(await _loader());
    }
    final bucket = DateTime.now().millisecondsSinceEpoch ~/
        _memoryTtl.inMilliseconds;
    // The GitHub Contents API is generally more reliable on mobile networks
    // than raw.githubusercontent.com. Raw content remains a no-auth fallback
    // in case the public Contents API rate limit is temporarily exhausted.
    for (final url in <String>[contentsUrl, remoteUrl]) {
      try {
        final separator = url.contains('?') ? '&' : '?';
        final response = await _dio.get<dynamic>(
          '$url${separator}news=$bucket',
          options: Options(headers: const {'Cache-Control': 'no-cache'}),
        );
        final remote = _decodeRemote(response.data);
        final feed = NewsFeed.fromJson(remote);
        if (feed.articles.isNotEmpty) return feed;
      } catch (_) {
        // Try the next remote endpoint before using the bundled snapshot.
      }
    }
    final raw = await _bundle.loadString('assets/news.json');
    final feed = NewsFeed.fromJson(_decode(raw));
    if (feed.articles.isEmpty) {
      throw const FormatException('新闻数据为空');
    }
    return feed;
  }

  Map<String, dynamic> _decodeRemote(dynamic value) {
    final envelope = _decode(value);
    if (envelope['encoding']?.toString() != 'base64') return envelope;
    final encoded = envelope['content']?.toString().replaceAll(
          RegExp(r'\s+'),
          '',
        );
    if (encoded == null || encoded.isEmpty) return <String, dynamic>{};
    return _decode(utf8.decode(base64Decode(encoded)));
  }

  Map<String, dynamic> _decode(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is String) {
      final decoded = jsonDecode(value);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    return <String, dynamic>{};
  }
}
