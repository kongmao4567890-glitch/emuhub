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
  })  : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 3),
                receiveTimeout: const Duration(seconds: 5),
                headers: const {
                  'Accept': 'application/json',
                  'User-Agent':
                      'EmuHub/1.0 (+https://github.com/kongmao4567890-glitch/emuhub)',
                },
              ),
            ),
        _bundle = bundle ?? rootBundle,
        _loader = loader;

  static const Duration _memoryTtl = Duration(minutes: 15);

  final Dio _dio;
  final AssetBundle _bundle;
  final NewsFeedLoader? _loader;
  final String remoteUrl;
  Future<NewsFeed>? _inFlight;
  DateTime? _loadedAt;

  Future<NewsFeed> load() {
    final now = DateTime.now();
    if (_inFlight != null &&
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
    try {
      final bucket = DateTime.now().millisecondsSinceEpoch ~/
          _memoryTtl.inMilliseconds;
      final response = await _dio.get<dynamic>('$remoteUrl?news=$bucket');
      final remote = _decode(response.data);
      final feed = NewsFeed.fromJson(remote);
      if (feed.articles.isNotEmpty) return feed;
    } catch (_) {
      // Network unavailable: the bundled snapshot below opens instantly.
    }
    final raw = await _bundle.loadString('assets/news.json');
    final feed = NewsFeed.fromJson(_decode(raw));
    if (feed.articles.isEmpty) {
      throw const FormatException('新闻数据为空');
    }
    return feed;
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
