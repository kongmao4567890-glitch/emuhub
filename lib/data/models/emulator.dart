import 'package:freezed_annotation/freezed_annotation.dart';

part 'emulator.freezed.dart';
part 'emulator.g.dart';

/// 单个模拟器条目，对应 emulators.json 中某个机种下的一个模拟器。
///
/// 字段说明：
/// - [sourceType] 取值为 `github` / `playstore` / `website`，决定更新来源抓取策略。
/// - [compatibility] 取值为 `perfect` / `high` / `good` / `medium` / `low`。
@freezed
class Emulator with _$Emulator {
  const factory Emulator({
    required String id,
    required String name,
    required bool openSource,
    required String sourceType, // github / playstore / website
    required String sourceUrl,
    required String playStoreId,
    required String website,
    required String core,
    required String compatibility, // perfect/high/good/medium/low
    required String minAndroid,
    required String description,
  }) = _Emulator;

  factory Emulator.fromJson(Map<String, dynamic> json) =>
      _$EmulatorFromJson(json);
}
