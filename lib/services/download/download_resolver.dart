import '../../data/models/emulator.dart';

/// 下载链接动态解析器。
///
/// 解决模拟器更新版本后，静态 downloadUrl 失效（404）的问题。
///
/// **工作原理**：
///
/// 1. **GitHub 源**：优先使用缓存中的 `resolvedDownloadUrl`（由适配器在
///    版本检查时从 API 提取）。若缓存为空，尝试将静态 URL 中的版本号
///    替换为 `latest/download` 形式。
///
/// 2. **非 GitHub 源**：当静态 URL 包含版本号时，使用最新版本号进行
///    替换。例如 Eden 的 URL 模板：
///    `https://stable.eden-emu.dev/v{version}/Eden-Android-v{version}-standard.apk`
///    传入最新版本号后自动生成有效链接。
///
/// 3. **回退**：所有解析失败时，返回原始静态 URL（由 UI 层决定如何处理）。
class DownloadResolver {
  DownloadResolver._();

  /// 解析稳定版下载链接。
  ///
  /// [emulator] 模拟器数据。
  /// [cachedDownloadUrl] 数据库缓存中的动态链接（由适配器写入），可为 null。
  /// [latestVersion] 最新版本号（如 `0.2.1`），用于非 GitHub 源的模板替换。
  ///
  /// 返回解析后的有效 URL。若全部失败，返回模拟器的静态 downloadUrl。
  static String resolveStableUrl(
    Emulator emulator, {
    String? cachedDownloadUrl,
    String? latestVersion,
  }) {
    // 优先使用缓存的动态链接
    if (cachedDownloadUrl != null && cachedDownloadUrl.isNotEmpty) {
      return cachedDownloadUrl;
    }

    final staticUrl = emulator.downloadUrl;
    if (staticUrl.isEmpty) return staticUrl;

    // 尝试根据版本号动态替换
    if (latestVersion != null && latestVersion.isNotEmpty) {
      final resolved = _tryReplaceVersion(staticUrl, latestVersion);
      if (resolved != null) return resolved;
    }

    return staticUrl;
  }

  /// 解析开发版下载链接。
  ///
  /// 优先使用缓存中的 `cachedDevDownloadUrl`（由适配器从 prerelease 提取）。
  /// 若缓存为空，回退到静态 devUrl。
  static String resolveDevUrl(
    Emulator emulator, {
    String? cachedDevDownloadUrl,
    String? latestVersion,
  }) {
    // 优先使用缓存的动态开发版链接
    if (cachedDevDownloadUrl != null && cachedDevDownloadUrl.isNotEmpty) {
      return cachedDevDownloadUrl;
    }

    final url = emulator.devUrl;
    if (url.isEmpty) return url;

    if (latestVersion != null && latestVersion.isNotEmpty) {
      final resolved = _tryReplaceVersion(url, latestVersion);
      if (resolved != null) return resolved;
    }

    return url;
  }

  /// 尝试将 URL 中的旧版本号替换为新版本号。
  ///
  /// 支持以下模式：
  /// - `v0.2.1` → `v{newVersion}`
  /// - `1.20.4` → `{newVersion}`
  /// - `2606`（YYMM 格式）→ 不替换（无法自动推断）
  ///
  /// 返回 null 表示无法替换或不适用于替换。
  static String? _tryReplaceVersion(String url, String newVersion) {
    // Eden 模式：stable.eden-emu.dev/v0.2.1/Eden-Android-v0.2.1-standard.apk
    // 同时替换路径中的版本号和文件名中的版本号
    final edenPattern = RegExp(r'v(\d+\.\d+\.\d+)');
    if (edenPattern.hasMatch(url)) {
      return url.replaceAll(edenPattern, 'v$newVersion');
    }

    // PPSSPP 模式：www.ppsspp.org/files/1_20_4/ppsspp.apk
    final ppssppPattern = RegExp(r'/files/(\d+_\d+_\d+)/');
    if (ppssppPattern.hasMatch(url)) {
      final versionPart = newVersion.replaceAll('.', '_');
      return url.replaceAll(ppssppPattern, '/files/$versionPart/');
    }

    // 通用模式：路径中包含 /v{version}/ 或 /{version}/
    final versionInPath = RegExp(r'/v?(\d+\.\d+(?:\.\d+)?)/');
    final matches = versionInPath.allMatches(url);
    if (matches.isNotEmpty) {
      var result = url;
      // 逆序替换，避免偏移问题
      for (final match in matches.toList().reversed) {
        result = result.substring(0, match.start) +
            '/v$newVersion/' +
            result.substring(match.end);
      }
      return result;
    }

    return null;
  }

  /// 判断 URL 是否可能因版本更新而失效（包含硬编码版本号）。
  ///
  /// 注意：`releases/latest/download/{asset}` 形式中，如果 asset 文件名
  /// 包含版本号（如 `ARMSX2-2.6.5.2.apk`），版本更新后 asset 名会变化，
  /// 导致 `latest/download/` 重定向 404。此类 URL 也被视为易变。
  static bool isUrlVolatile(String url) {
    if (url.isEmpty) return false;
    // GitHub releases 页面不会失效
    if (url.endsWith('/releases')) return false;
    // Play Store 链接不会失效
    if (url.contains('play.google.com')) return false;
    // GitHub latest/download/{asset} 形式：检查 asset 名是否含版本号
    if (url.contains('/releases/latest/download/')) {
      final assetMatch =
          RegExp(r'/releases/latest/download/(.+)$').firstMatch(url);
      if (assetMatch != null) {
        final asset = assetMatch.group(1)!;
        // asset 名含版本号 → 易变
        if (RegExp(r'\d+\.\d+\.\d+').hasMatch(asset)) return true;
        if (RegExp(r'\d+\.\d+').hasMatch(asset)) return true;
      }
      // asset 名为静态 → 不易变
      return false;
    }
    // 包含版本号模式的 URL 会失效
    if (RegExp(r'/v?\d+\.\d+\.\d+/').hasMatch(url)) return true;
    if (RegExp(r'/v?\d+\.\d+/').hasMatch(url)) return true;
    return false;
  }
}
