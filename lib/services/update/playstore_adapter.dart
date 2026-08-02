import 'package:dio/dio.dart';
import 'package:html/parser.dart';

import '../../data/models/emulator.dart';
import '../../data/models/version_info.dart';
import 'version_adapter.dart';

/// 基于 Google Play 商店页面的版本适配器。
///
/// 适用于 [Emulator.sourceType] 为 `playstore` 的模拟器。请求应用详情页
/// （`https://play.google.com/store/apps/details?id={playStoreId}&hl=zh`），
/// 使用 [html](https://pub.dev/packages/html) 解析并尝试多种方式提取版本号
/// 与更新日期。
///
/// Play Store 页面结构经常变化，因此采用多策略兜底：
/// 1. `[[\"版本号\",\"x.y.z\"]]` 形式的 JSON 片段；
/// 2. `\"版本号\",\"x.y.z\"` 形式的扁平片段；
/// 3. `\"currentVersion\":\"x.y.z\"` 形式的字段；
/// 4. `<meta name="version">` 标签内容；
/// 5. `itemprop="softwareVersion"` 结构化字段。
///
/// 任意解析失败均返回 `null`，不抛出异常。
class PlayStoreAdapter implements VersionAdapter {
  PlayStoreAdapter({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 20),
                followRedirects: true,
              ),
            );

  final Dio _dio;

  @override
  String get adapterName => 'playstore';

  @override
  Future<VersionInfo?> fetchLatestVersion(
    Emulator emulator, {
    bool includeDetails = false,
  }) async {
    final playStoreId = emulator.playStoreId;
    if (playStoreId.isEmpty) return null;

    try {
      final response = await _dio.get(
        'https://play.google.com/store/apps/details',
        queryParameters: {
          'id': playStoreId,
          'hl': 'zh',
        },
        options: Options(responseType: ResponseType.plain),
      );
      final html = response.data.toString();

      final version = _extractVersion(html);
      if (version == null || version.isEmpty) return null;

      final releaseDate = _extractUpdateDate(html);

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: releaseDate,
        releaseNotes: null,
        isNew: false,
      );
    } catch (_) {
      return null;
    }
  }

  /// 多策略提取版本号。
  String? _extractVersion(String html) {
    // 策略 1：[["版本号","x.y.z"]]
    final match1 = RegExp(r'\[\["版本号"\s*,\s*"([^"]+)"\]\]')
        .firstMatch(html);
    if (match1 != null) return _cleanVersion(match1.group(1)!);

    // 策略 2："版本号","x.y.z"
    final match2 =
        RegExp(r'"版本号"\s*,\s*"([^"]+)"').firstMatch(html);
    if (match2 != null) return _cleanVersion(match2.group(1)!);

    // 策略 3："currentVersion":"x.y.z" / "version":"x.y.z"
    final match3 = RegExp(
      r'"(?:currentVersion|version)"\s*:\s*"([^"]+)"',
    ).firstMatch(html);
    if (match3 != null) return _cleanVersion(match3.group(1)!);

    // 策略 4：meta 标签
    try {
      final document = parse(html);
      final meta = document.querySelector('meta[name="version"]');
      final content = meta?.attributes['content'];
      if (content != null && content.isNotEmpty) {
        return _cleanVersion(content);
      }
    } catch (_) {
      // 忽略解析错误
    }

    // 策略 5：旧版 Play 页面使用过的结构化 softwareVersion 字段。
    // 不使用“页面中第一个 x.y.z”作为兜底，因为它经常是脚本/协议版本，
    // 会产生不存在的新版本通知。
    final match5 = RegExp(
      r'itemprop="softwareVersion"[^>]*>\s*([^<]+)',
      caseSensitive: false,
    ).firstMatch(html);
    if (match5 != null) return _cleanVersion(match5.group(1)!);

    return null;
  }

  /// 提取更新日期，支持 ISO 日期与中文日期（如 `2024年1月15日`）。
  DateTime? _extractUpdateDate(String html) {
    final match =
        RegExp(r'"更新日期"\s*,\s*"([^"]+)"').firstMatch(html) ??
            RegExp(r'更新日期[：:\s]*([^\s"<,]+)').firstMatch(html);
    if (match == null) return null;
    return _parseDate(match.group(1));
  }

  /// 解析日期字符串，支持 ISO 与中文格式。
  DateTime? _parseDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return null;

    // 先尝试 ISO 8601
    try {
      return DateTime.parse(dateStr);
    } catch (_) {
      // 继续尝试其它格式
    }

    // 中文日期：2024年1月15日
    final cnMatch = RegExp(r'(\d{4})年(\d{1,2})月(\d{1,2})日').firstMatch(dateStr);
    if (cnMatch != null) {
      try {
        return DateTime(
          int.parse(cnMatch.group(1)!),
          int.parse(cnMatch.group(2)!),
          int.parse(cnMatch.group(3)!),
        );
      } catch (_) {
        return null;
      }
    }

    return null;
  }

  String _cleanVersion(String version) => version.trim();
}
