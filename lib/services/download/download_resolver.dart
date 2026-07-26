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

  /// 解析每夜版下载链接。
  ///
  /// 优先使用缓存中的 `cachedNightlyDownloadUrl`（由适配器从 CI 仓库提取）。
  /// 若缓存为空，回退到静态 nightlyUrl。
  static String resolveNightlyUrl(
    Emulator emulator, {
    String? cachedNightlyDownloadUrl,
  }) {
    if (cachedNightlyDownloadUrl != null &&
        cachedNightlyDownloadUrl.isNotEmpty) {
      return cachedNightlyDownloadUrl;
    }
    return emulator.nightlyUrl;
  }

  /// 解析预览版下载链接。
  ///
  /// 优先使用缓存中的 `cachedPreviewDownloadUrl`（由适配器从 prerelease 提取）。
  /// 若缓存为空，回退到静态 previewUrl。
  static String resolvePreviewUrl(
    Emulator emulator, {
    String? cachedPreviewDownloadUrl,
  }) {
    if (cachedPreviewDownloadUrl != null &&
        cachedPreviewDownloadUrl.isNotEmpty) {
      return cachedPreviewDownloadUrl;
    }
    return emulator.previewUrl;
  }

  /// 判断 URL 是否为直接下载链接（APK 文件或等效的下载重定向）。
  ///
  /// 返回 `true` 的情况：
  /// - URL 以 `.apk` 结尾（含带查询参数的情况如 `.apk?token=xxx`）
  /// - Play Store 链接（打开应用商店安装，可接受）
  /// - GitHub `releases/latest/download/` 链接（302 重定向到 APK 文件）
  /// - GitHub/Forgejo/Gitea `releases/download/` 链接（直接 APK 下载）
  /// - SourceForge `/download` 链接（重定向下载）
  /// - F-Droid 仓库直链（以 `.apk` 结尾，已被第一条覆盖）
  ///
  /// 返回 `false` 的情况（打开的是网页而非直接下载）：
  /// - GitHub `/releases` 列表页面
  /// - GitLab `/-/releases` 页面
  /// - Forgejo `/releases` 页面
  /// - 项目官网下载页面
  /// - docs.libretro.com 文档页面
  static bool isDirectDownloadUrl(String url) {
    if (url.isEmpty) return false;
    final lower = url.toLowerCase();
    // 直接 APK 文件（可能带查询参数或锚点）
    if (RegExp(r'\.apk([?#]|$)').hasMatch(lower)) return true;
    // Play Store（打开应用商店，可接受）
    if (url.contains('play.google.com')) return true;
    // GitHub latest/download（302 重定向到 APK 文件）
    if (lower.contains('/releases/latest/download/')) return true;
    // GitHub/Forgejo/Gitea releases/download/{tag}/{asset}（直接 APK 下载）
    if (lower.contains('/releases/download/')) return true;
    // GitLab releases downloads（/-/releases/{tag}/downloads/{asset}）
    if (lower.contains('/-/releases/') && lower.contains('/downloads/')) {
      return true;
    }
    // GitLab uploads（/uploads/{hash}/{asset}.apk）
    if (lower.contains('/uploads/') && lower.contains('.apk')) return true;
    // SourceForge latest/download（重定向下载）
    if (url.contains('sourceforge.net') &&
        url.contains('/latest/download')) return true;
    // SourceForge /download 端点（文件下载页，触发下载）
    if (url.contains('sourceforge.net') &&
        (lower.endsWith('/download') || lower.contains('/download?'))) {
      return true;
    }
    return false;
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
