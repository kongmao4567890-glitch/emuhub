import 'package:dio/dio.dart';

/// MyMemory 翻译服务（免费端点）。
///
/// 使用 MyMemory Translation API 进行翻译，无需 API Key。
/// 端点：`https://api.mymemory.translated.net/get`
///
/// 作为 Google 翻译的备选方案，在中国大陆环境下 Google 翻译不可用时使用。
/// MyMemory 在中国大陆可正常访问。
///
/// 限制：
/// - 匿名用户每日约 5000 词翻译配额
/// - 单次请求文本不超过 500 字符
/// - 长文本需分段翻译
class MyMemoryTranslateService {
  MyMemoryTranslateService._();

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  /// 单次翻译请求的最大文本长度（字符数）。
  ///
  /// MyMemory 匿名端点限制单次请求约 500 字符。
  static const int _maxChunkLength = 500;

  /// 内存缓存上限。
  static const int _maxCacheSize = 200;

  /// 内存缓存（LRU 淘汰）。
  static final Map<String, String> _cache = {};

  /// 将文本翻译为中文。
  ///
  /// 成功返回翻译后的中文字符串。
  /// 失败返回 `null`（网络错误、配额用尽、解析失败等）。
  static Future<String?> translateToChinese(String text) async {
    if (text.isEmpty) return text;

    // 检查缓存
    final cacheKey = text.trim();
    if (_cache.containsKey(cacheKey)) {
      final value = _cache.remove(cacheKey)!;
      _cache[cacheKey] = value;
      return value;
    }

    // 按段落拆分长文本
    final chunks = _splitIntoChunks(text, _maxChunkLength);
    final translatedChunks = <String>[];

    for (final chunk in chunks) {
      final result = await _translateSingle(chunk);
      if (result == null) {
        // 配额用尽或网络错误
        return null;
      }
      // MyMemory 对警告信息（如配额提醒）仍然返回 200，
      // 但 translatedText 会包含 "MYMEMORY WARNING" 文本
      if (result.contains('MYMEMORY WARNING')) {
        return null;
      }
      translatedChunks.add(result);
    }

    final result = translatedChunks.join('\n').trim();
    if (result.isEmpty) return null;

    // 写入缓存
    _cache[cacheKey] = result;
    if (_cache.length > _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }

    return result;
  }

  /// 翻译单段文本（不超过 [_maxChunkLength] 字符）。
  static Future<String?> _translateSingle(String text) async {
    if (text.trim().isEmpty) return text;

    try {
      final response = await _dio.get(
        'https://api.mymemory.translated.net/get',
        queryParameters: {
          'q': text,
          'langpair': 'en|zh-CN',
        },
        options: Options(
          responseType: ResponseType.json,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
        ),
      );

      final data = response.data;
      if (data is! Map) return null;

      final responseStatus = data['responseStatus'];
      // responseStatus 为 200 或 null 时表示成功
      // 429 表示配额用尽
      if (responseStatus == 429) return null;

      final responseData = data['responseData'];
      if (responseData is! Map) return null;

      final translatedText = responseData['translatedText'];
      if (translatedText is! String) return null;

      final result = translatedText.trim();
      return result.isEmpty ? null : result;
    } catch (_) {
      return null;
    }
  }

  /// 将长文本拆分为不超过 [maxLen] 字符的片段。
  ///
  /// 优先在换行符处拆分，其次在句号/问号/感叹号处拆分。
  static List<String> _splitIntoChunks(String text, int maxLen) {
    if (text.length <= maxLen) return [text];

    final chunks = <String>[];
    final lines = text.split('\n');
    var current = StringBuffer();

    for (final line in lines) {
      if (line.length > maxLen) {
        if (current.isNotEmpty) {
          chunks.add(current.toString());
          current = StringBuffer();
        }
        chunks.addAll(_splitLongLine(line, maxLen));
        continue;
      }

      if (current.length + line.length + 1 > maxLen) {
        if (current.isNotEmpty) {
          chunks.add(current.toString());
          current = StringBuffer();
        }
      }

      if (current.isNotEmpty) {
        current.write('\n');
      }
      current.write(line);
    }

    if (current.isNotEmpty) {
      chunks.add(current.toString());
    }

    return chunks;
  }

  /// 拆分超长行。
  static List<String> _splitLongLine(String line, int maxLen) {
    final chunks = <String>[];
    var start = 0;

    while (start < line.length) {
      final end =
          (start + maxLen < line.length) ? start + maxLen : line.length;
      if (end >= line.length) {
        chunks.add(line.substring(start));
        break;
      }

      var cutAt = -1;
      for (var i = end - 1; i > start; i--) {
        final ch = line[i];
        if (ch == '.' || ch == '!' || ch == '?' || ch == ';' || ch == '\n') {
          cutAt = i + 1;
          break;
        }
      }

      if (cutAt <= start) {
        cutAt = line.lastIndexOf(' ', end);
        if (cutAt <= start) cutAt = end;
      }

      chunks.add(line.substring(start, cutAt));
      start = cutAt;
    }

    return chunks;
  }
}
