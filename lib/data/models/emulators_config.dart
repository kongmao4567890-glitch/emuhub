import 'package:freezed_annotation/freezed_annotation.dart';

import 'console.dart';

part 'emulators_config.freezed.dart';
part 'emulators_config.g.dart';

/// emulators.json 顶层配置结构。
///
/// [version] 为配置文件版本号，[lastUpdated] 为配置文件最后更新日期
/// （ISO 8601 日期字符串），[consoles] 为机种列表。
@freezed
class EmulatorsConfig with _$EmulatorsConfig {
  const factory EmulatorsConfig({
    required String version,
    required String lastUpdated,
    required List<Console> consoles,
  }) = _EmulatorsConfig;

  factory EmulatorsConfig.fromJson(Map<String, dynamic> json) =>
      _$EmulatorsConfigFromJson(json);
}
