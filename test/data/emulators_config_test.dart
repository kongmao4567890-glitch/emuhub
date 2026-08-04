import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:emuhub/data/models/emulator.dart';
import 'package:emuhub/data/models/emulators_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled emulator configuration is valid and has unique ids', () async {
    final raw = await rootBundle.loadString('assets/emulators.json');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final config = EmulatorsConfig.fromJson(decoded);

    expect(config.consoles, isNotEmpty);
    expect(config.lastUpdated, isNotEmpty);

    final consoleIds = <String>{};
    final emulatorIds = <String>{};
    const supportedSources = {
      'github',
      'gitlab',
      'forgejo',
      'playstore',
      'website',
    };
    const supportedPlatforms = {
      'android',
      'windows',
      'linux',
      'macos',
    };

    for (final console in config.consoles) {
      expect(consoleIds.add(console.id), isTrue, reason: console.id);
      expect(console.name, isNotEmpty, reason: console.id);

      for (final emulator in console.emulators) {
        expect(emulatorIds.add(emulator.id), isTrue, reason: emulator.id);
        expect(emulator.name, isNotEmpty, reason: emulator.id);
        expect(
          supportedSources,
          contains(emulator.sourceType),
          reason: emulator.id,
        );
        expect(emulator.platforms, isNotEmpty, reason: emulator.id);
        expect(
          emulator.platforms.toSet().length,
          emulator.platforms.length,
          reason: emulator.id,
        );
        for (final platform in emulator.platforms) {
          expect(supportedPlatforms, contains(platform), reason: emulator.id);
        }
        if (emulator.supportsPlatform('android')) {
          expect(emulator.minAndroid, isNotEmpty, reason: emulator.id);
        }
        if (emulator.supportsDesktop) {
          expect(emulator.desktopRequirements, isNotEmpty,
              reason: emulator.id);
        }

        for (final url in [
          emulator.sourceUrl,
          emulator.website,
          emulator.downloadUrl,
          emulator.devUrl,
          emulator.nightlyUrl,
        ]) {
          if (url.isEmpty) continue;
          final uri = Uri.tryParse(url);
          expect(uri, isNotNull, reason: '${emulator.id}: $url');
          expect(
            uri!.scheme == 'https' || uri.scheme == 'http',
            isTrue,
            reason: '${emulator.id}: $url',
          );
        }

        if (emulator.playStoreId.isNotEmpty) {
          expect(
            RegExp(
              r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$',
            ).hasMatch(emulator.playStoreId),
            isTrue,
            reason: '${emulator.id}: ${emulator.playStoreId}',
          );
        }

        if (emulator.sourceType == 'playstore') {
          if (emulator.playStoreId.isEmpty) {
            expect(emulator.downloadUrl, isEmpty, reason: emulator.id);
          } else {
            expect(
              emulator.downloadUrl,
              'https://play.google.com/store/apps/details?id=${emulator.playStoreId}',
              reason: emulator.id,
            );
          }
        }

        // 固定资产名会在项目发布新版本并修改文件名后立即变成 404。
        // GitHub 适配器会在检查更新时动态取得当前 Release 的实际资产。
        expect(
          emulator.downloadUrl.contains('/releases/latest/download/'),
          isFalse,
          reason: emulator.id,
        );

        if (emulator.downloadUrl.contains(
          'play.google.com/store/apps/details',
        )) {
          expect(emulator.sourceType, 'playstore', reason: emulator.id);
          expect(emulator.playStoreId, isNotEmpty, reason: emulator.id);
        }
      }
    }

    final armsx1 = config.consoles
        .expand((console) => console.emulators)
        .singleWhere(
          (emulator) => emulator.id == 'armsx1',
        );
    expect(armsx1.sourceType, 'github');
    expect(armsx1.iconPath, 'assets/emulators/armsx1.png');
    final armsx1Icon = await rootBundle.load(armsx1.iconPath);
    expect(armsx1Icon.lengthInBytes, greaterThan(0));

    expect(consoleIds.length, 120);
    expect(emulatorIds.length, 284);
    expect(consoleIds, containsAll({'ps5', 'sharp_mz', 'emulation_tools'}));
    expect(
      emulatorIds,
      containsAll({
        'mesence_pc',
        'pcsx_redux_pc',
        'coffee_gb_pc',
        'noods',
        'sharpemu_pc',
        'steam_rom_manager',
        'retrobat',
        'padforge',
        'adamp_pc',
        'sidplaywx',
      }),
    );

    final pcEmulators = config.consoles
        .expand((console) => console.emulators)
        .where((emulator) => emulator.supportsDesktop)
        .toList();
    expect(pcEmulators.length, greaterThanOrEqualTo(130));
    expect(pcEmulators.any((emulator) => emulator.id == 'pcsx2_pc'), isTrue);
    expect(pcEmulators.any((emulator) => emulator.id == 'rpcs3_pc'), isTrue);
    expect(pcEmulators.any((emulator) => emulator.id == 'xenia_pc'), isTrue);
    expect(pcEmulators.any((emulator) => emulator.id == 'cemu_pc'), isTrue);
    expect(pcEmulators.any((emulator) => emulator.id == 'ryubing_pc'), isTrue);

    for (final emulator in pcEmulators) {
      expect(emulator.iconPath, isNotEmpty, reason: emulator.id);
      final icon = await rootBundle.load(emulator.iconPath);
      expect(icon.lengthInBytes, greaterThan(0), reason: emulator.id);
    }

    for (final console in config.consoles) {
      if (console.id == 'gpu_drivers') continue;
      expect(
        console.emulators.any((emulator) => emulator.supportsDesktop),
        isTrue,
        reason: '${console.id} 缺少 PC 平台模拟器',
      );
    }
  });
}
