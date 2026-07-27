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
class GoogleTranslateService {
  GoogleTranslateService._();

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  /// 内存缓存：避免对相同文本重复请求翻译。
  static final Map<String, String> _cache = {};

  /// 将英文文本翻译为中文。
  ///
  /// 成功返回翻译后的中文字符串。
  /// 失败返回 `null`（网络错误、解析失败等）。
  static Future<String?> translateToChinese(String text) async {
    if (text.isEmpty) return text;

    // 检查缓存
    final cacheKey = text.trim();
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey];
    }

    try {
      final response = await _dio.get(
        'https://translate.googleapis.com/translate_a/single',
        queryParameters: {
          'client': 'gtx',
          'sl': 'en', // 源语言：英文
          'tl': 'zh-CN', // 目标语言：简体中文
          'dt': 't', // 返回翻译结果
          'q': text,
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
      if (data is! List || data.isEmpty) return null;

      // Google Translate 返回格式：[[["translated","original",...],...],...]
      // 第一层数组的每个元素是一句话的翻译
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
      if (result.isEmpty) return null;

      // 写入缓存
      _cache[cacheKey] = result;
      return result;
    } catch (_) {
      return null;
    }
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
