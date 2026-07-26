import 'package:freezed_annotation/freezed_annotation.dart';

part 'version_info.freezed.dart';
part 'version_info.g.dart';

/// 模拟器版本检查结果。
///
/// 由更新检查服务从 GitHub Release / Play Store 等渠道抓取后生成，
/// [isNew] 表示相对于本地已缓存版本是否为新增版本。
///
/// [downloadUrl] 为适配器抓取到的最新版本直链下载地址（如 GitHub Release
/// 的 APK asset URL）。当模拟器更新版本后，旧的静态 downloadUrl 会失效，
/// 此字段提供动态解析后的有效链接，避免 404。
@freezed
class VersionInfo with _$VersionInfo {
  const factory VersionInfo({
    required String emulatorId,
    required String version,
    required DateTime releaseDate,
    String? releaseNotes,
    required bool isNew,

    /// 适配器抓取到的最新**稳定版**直链下载地址（动态，随版本更新而变化）。
    ///
    /// 为 `null` 表示适配器未能解析到直链，调用方应回退到静态 downloadUrl。
    String? downloadUrl,

    /// 适配器抓取到的最新**开发版/预览版**直链下载地址（动态）。
    ///
    /// 从 GitHub prerelease 的 assets 中提取。为 `null` 时回退到静态 devUrl。
    String? devDownloadUrl,

    /// 适配器抓取到的最新**每夜版/CI构建**直链下载地址（动态）。
    ///
    /// 从 nightlyUrl 对应的 GitHub 仓库的 releases 中提取。
    /// 为 `null` 时回退到静态 nightlyUrl。
    String? nightlyDownloadUrl,
  }) = _VersionInfo;

  factory VersionInfo.fromJson(Map<String, dynamic> json) =>
      _$VersionInfoFromJson(json);
}
