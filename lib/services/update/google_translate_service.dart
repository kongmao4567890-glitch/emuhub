import 'package:dio/dio.dart';

/// Google 翻译服务（免费端点）。
///
/// 使用 Google Translate 的免费网页端点进行翻译，无需 API Key。
/// 端点：`https://translate.googleapis.com/translate_a/single`
///
/// 限制：
/// - 非官方端点，可能随时变更
/// - 适合短文本翻译，不适合大量请求
/// - 返回的是嵌套数组 JSON
///
/// **长文本处理**：release notes 可能长达数千甚至上万字符（如 ARMSX2 2.5.0
/// 有近 2 万字符），远超 GET 请求的 URL 长度限制。本服务会将长文本按段落
/// 拆分为不超过 [_maxChunkLength] 字符的片段，逐段翻译后拼接，每段使用
/// POST 请求发送以彻底规避 URL 长度限制。
class GoogleTranslateService {
  GoogleTranslateService._();

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  /// 单次翻译请求的最大文本长度（字符数）。
  ///
  /// Google 免费端点对单次请求有隐含限制，保守取 1500 字符以确保稳定。
  /// 超过此长度的文本会被拆分为多段分别翻译。
  static const int _maxChunkLength = 1500;

  /// 内存缓存上限，超过后按 LRU 策略淘汰最旧条目。
  static const int _maxCacheSize = 200;

  /// 内存缓存：避免对相同文本重复请求翻译（LRU 淘汰）。
  static final Map<String, String> _cache = {};

  /// 将文本翻译为中文。
  ///
  /// 成功返回翻译后的中文字符串。
  /// 失败返回 `null`（网络错误、解析失败等）。
  ///
  /// 长文本会自动分段翻译后拼接。
  static Future<String?> translateToChinese(String text) async {
    if (text.isEmpty) return text;

    // 检查缓存
    final cacheKey = text.trim();
    if (_cache.containsKey(cacheKey)) {
      // LRU: 重新插入以移到末尾（最近使用）
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
        // 任一段翻译失败则整体失败
        return null;
      }
      translatedChunks.add(result);
    }

    final result = translatedChunks.join('\n').trim();
    if (result.isEmpty) return null;

    // 写入缓存（带 LRU 淘汰）
    _cache[cacheKey] = result;
    if (_cache.length > _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }

    return result;
  }

  /// 翻译单段文本（不超过 [_maxChunkLength] 字符）。
  ///
  /// 由于每段已被限制在 [_maxChunkLength] 以内，GET URL 不会超长。
  /// 先尝试 GET（兼容性最好），失败后再尝试 POST（某些网络环境 POST 更稳定）。
  /// 源语言设为 `auto` 自动检测，支持英文/日文/其他语种的 release notes。
  static Future<String?> _translateSingle(String text) async {
    if (text.trim().isEmpty) return text;

    final queryParams = {
      'client': 'gtx',
      'sl': 'auto', // 自动检测源语言
      'tl': 'zh-CN', // 目标语言：简体中文
      'dt': 't', // 返回翻译结果
      'q': text,
    };

    // 尝试 1: GET 请求（分段后 URL 不会超长）
    var result = await _tryTranslateGet(queryParams);
    if (result != null) return result;

    // 尝试 2: POST 请求（某些网络环境下 POST 更可靠）
    result = await _tryTranslatePost(queryParams);
    return result;
  }

  /// 通过 GET 请求翻译。
  static Future<String?> _tryTranslateGet(
      Map<String, dynamic> params) async {
    try {
      final response = await _dio.get(
        'https://translate.googleapis.com/translate_a/single',
        queryParameters: params,
        options: Options(
          responseType: ResponseType.json,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
        ),
      );
      return _parseTranslateResponse(response.data);
    } catch (_) {
      return null;
    }
  }

  /// 通过 POST 请求翻译。
  static Future<String?> _tryTranslatePost(
      Map<String, dynamic> params) async {
    try {
      final text = params['q'] as String;
      final response = await _dio.post(
        'https://translate.googleapis.com/translate_a/single',
        queryParameters: {
          'client': 'gtx',
          'sl': 'auto',
          'tl': 'zh-CN',
          'dt': 't',
        },
        data: {'q': text},
        options: Options(
          responseType: ResponseType.json,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        ),
      );
      return _parseTranslateResponse(response.data);
    } catch (_) {
      return null;
    }
  }

  /// 解析 Google Translate 返回的嵌套数组 JSON。
  static String? _parseTranslateResponse(dynamic data) {
    if (data is! List || data.isEmpty) return null;

    final sentences = data[0];
    if (sentences is! List) return null;

    final buffer = StringBuffer();
    for (final sentence in sentences) {
      if (sentence is List && sentence.isNotEmpty) {
        final translated = sentence[0];
        if (translated is String) {
          buffer.write(translated);
        }
      }
    }

    final result = buffer.toString().trim();
    return result.isEmpty ? null : result;
  }

  /// 将长文本拆分为不超过 [maxLen] 字符的片段。
  ///
  /// 优先在换行符处拆分，其次在句号/问号/感叹号处拆分，
  /// 最后在空格处拆分，尽量保持语义完整。
  static List<String> _splitIntoChunks(String text, int maxLen) {
    if (text.length <= maxLen) return [text];

    final chunks = <String>[];
    final lines = text.split('\n');
    var current = StringBuffer();

    for (final line in lines) {
      // 如果当前行本身就超过 maxLen，需要进一步拆分
      if (line.length > maxLen) {
        // 先把已累积的内容推入 chunks
        if (current.isNotEmpty) {
          chunks.add(current.toString());
          current = StringBuffer();
        }
        // 按句子拆分超长行
        chunks.addAll(_splitLongLine(line, maxLen));
        continue;
      }

      // 检查加入这行后是否超限
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

  /// 拆分超长行：优先在句号、问号、感叹号后拆分。
  static List<String> _splitLongLine(String line, int maxLen) {
    final chunks = <String>[];
    var start = 0;

    while (start < line.length) {
      final end = (start + maxLen < line.length) ? start + maxLen : line.length;
      if (end >= line.length) {
        chunks.add(line.substring(start));
        break;
      }

      // 在 [start, end) 范围内找最后一个句子结束符
      var cutAt = -1;
      for (var i = end - 1; i > start; i--) {
        final ch = line[i];
        if (ch == '.' || ch == '!' || ch == '?' || ch == ';' || ch == '\n') {
          cutAt = i + 1;
          break;
        }
      }

      if (cutAt <= start) {
        // 找不到句子边界，在最后一个空格处拆分
        cutAt = line.lastIndexOf(' ', end);
        if (cutAt <= start) cutAt = end; // 实在找不到就硬切
      }

      chunks.add(line.substring(start, cutAt));
      start = cutAt;
    }

    return chunks;
  }

  /// 判断文本是否主要是英文（需要翻译）。
  ///
  /// 如果文本中中文字符占比已经很高，则不需要翻译。
  static bool needsTranslation(String text) {
    if (text.isEmpty) return false;

    int chineseCount = 0;
    int letterCount = 0;

    for (final char in text.runes) {
      // CJK 统一汉字范围
      if (char >= 0x4E00 && char <= 0x9FFF) {
        chineseCount++;
      } else if ((char >= 0x41 && char <= 0x5A) ||
          (char >= 0x61 && char <= 0x7A)) {
        letterCount++;
      }
    }

    // 如果英文字母数量多于中文字符，认为需要翻译
    return letterCount > chineseCount;
  }
}
