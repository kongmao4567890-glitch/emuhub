import 'package:dio/dio.dart';

import '../../data/models/emulator.dart';
import '../../data/models/version_info.dart';
import 'version_adapter.dart';

/// 基于官网页面的版本适配器。
///
/// 适用于 [Emulator.sourceType] 为 `website` 的模拟器。优先请求
/// [Emulator.sourceUrl] 指向的机器可读发布源，未配置时回退到
/// [Emulator.website]，再尝试用正则从 HTML / JSON / 纯文本中提取版本号。
///
/// 支持的版本号模式（按优先级）：
/// 1. `version 1.2.3` / `Version: 1.2` 等带关键字的形式；
/// 2. `v1.2.3` / `V1.2.3` 形式；
/// 3. `1.2.3.4` 形式；
/// 4. `1.2` 形式（兜底）。
///
/// 解析失败返回 `null`，不抛出异常。
class WebsiteAdapter implements VersionAdapter {
  WebsiteAdapter({Dio? dio})
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
  String get adapterName => 'website';

  @override
  Future<VersionInfo?> fetchLatestVersion(
    Emulator emulator, {
    bool includeDetails = false,
  }) async {
    final url = emulator.sourceUrl.trim().isNotEmpty
        ? emulator.sourceUrl.trim()
        : emulator.website.trim();
    if (url.isEmpty) return null;

    try {
      final response = await _dio.get(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      final content = response.data.toString();

      final version = _extractVersion(content);
      if (version == null || version.isEmpty) return null;

      return VersionInfo(
        emulatorId: emulator.id,
        version: version,
        releaseDate: null,
        releaseNotes: null,
        isNew: false,
      );
    } catch (_) {
      return null;
    }
  }

  /// 多模式正则提取版本号。
  String? _extractVersion(String content) {
    final patterns = <RegExp>[
      // version 1.2.3 / Version: 1.2 / Version-1.2.3
      RegExp(r'[Vv]ersion\s*[:\-]?\s*(\d+\.\d+(?:\.\d+)*[\.\d]*)'),
      // v1.2.3 / V1.2.3
      RegExp(r'[Vv](\d+\.\d+(?:\.\d+)*[\.\d]*)'),
      // 1.2.3.4
      RegExp(r'(\d+\.\d+\.\d+(?:\.\d+)*)'),
      // 1.2
      RegExp(r'(\d+\.\d+)'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(content);
      if (match != null) {
        final v = match.group(1);
        if (v != null && v.isNotEmpty) {
          return _cleanVersion(v);
        }
      }
    }
    return null;
  }

  String _cleanVersion(String version) {
    // 去掉末尾多余的点号
    var v = version.trim();
    while (v.endsWith('.')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }
}
