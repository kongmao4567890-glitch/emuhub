import 'package:freezed_annotation/freezed_annotation.dart';

part 'emulator.freezed.dart';
part 'emulator.g.dart';

/// 单个模拟器条目，对应 emulators.json 中某个机种下的一个模拟器。
///
/// 字段说明：
/// - [sourceType] 取值为 `github` / `gitlab` / `playstore` / `website`，决定更新来源抓取策略。
/// - [downloadUrl] 稳定版直接下载 APK 链接（动态指向最新版本），为空时回退到 Releases 页面。
/// - [devUrl] 最新开发版/预览版下载链接，为空表示无独立开发版渠道。
/// - [nightlyUrl] 每夜版/持续构建版下载链接，为空表示无每夜版渠道。
/// - [compatibility] 取值为 `perfect` / `high` / `good` / `medium` / `low`。
@freezed
class Emulator with _$Emulator {
  const factory Emulator({
    required String id,
    required String name,
    required bool openSource,
    required String sourceType, // github / gitlab / playstore / website
    required String sourceUrl,
    required String playStoreId,
    required String website,
    required String core,
    required String compatibility, // perfect/high/good/medium/low
    required String minAndroid,
    required String description,
    @Default('') String downloadUrl,
    @Default('') String devUrl,
    @Default('') String nightlyUrl,
    /// 模拟器官方图标资源路径（如 assets/emulators/dolphin.png）。
    /// 为空时回退到通用手柄图标。
    @Default('') String iconPath,
  }) = _Emulator;

  factory Emulator.fromJson(Map<String, dynamic> json) =>
      _$EmulatorFromJson(json);
}
