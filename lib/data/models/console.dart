import 'package:freezed_annotation/freezed_annotation.dart';

import 'emulator.dart';

part 'console.freezed.dart';
part 'console.g.dart';

/// 主机机种模型，对应 emulators.json 中的每一个 console 条目。
///
/// 一个机种下包含若干 [Emulator]。
/// [imagePath] 为机种图片资源路径，为空时回退到 [icon] emoji。
@freezed
class Console with _$Console {
  const factory Console({
    required String id,
    required String name,
    required String vendor,
    required int year,
    required String icon,
    required String description,
    required List<Emulator> emulators,
    @Default('') String imagePath,
  }) = _Console;

  factory Console.fromJson(Map<String, dynamic> json) =>
      _$ConsoleFromJson(json);
}
