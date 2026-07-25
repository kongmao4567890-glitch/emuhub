import 'package:freezed_annotation/freezed_annotation.dart';

part 'version_info.freezed.dart';
part 'version_info.g.dart';

/// 模拟器版本检查结果。
///
/// 由更新检查服务从 GitHub Release / Play Store 等渠道抓取后生成，
/// [isNew] 表示相对于本地已缓存版本是否为新增版本。
@freezed
class VersionInfo with _$VersionInfo {
  const factory VersionInfo({
    required String emulatorId,
    required String version,
    required DateTime releaseDate,
    String? releaseNotes,
    required bool isNew,
  }) = _VersionInfo;

  factory VersionInfo.fromJson(Map<String, dynamic> json) =>
      _$VersionInfoFromJson(json);
}
