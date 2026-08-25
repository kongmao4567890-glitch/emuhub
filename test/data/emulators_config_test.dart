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
    const supportedCompatibility = {
      'perfect',
      'high',
      'good',
      'medium',
      'low',
    };

    for (final console in config.consoles) {
      expect(consoleIds.add(console.id), isTrue, reason: console.id);
      expect(console.name, isNotEmpty, reason: console.id);
      expect(console.imagePath, isNotEmpty, reason: console.id);
      final consoleImage = await rootBundle.load(console.imagePath);
      expect(
        consoleImage.lengthInBytes,
        greaterThan(0),
        reason: console.id,
      );

      for (final emulator in console.emulators) {
        expect(emulatorIds.add(emulator.id), isTrue, reason: emulator.id);
        expect(emulator.name, isNotEmpty, reason: emulator.id);
        expect(
          supportedSources,
          contains(emulator.sourceType),
          reason: emulator.id,
        );
        expect(
          supportedCompatibility,
          contains(emulator.compatibility),
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

    final ryubing = config.consoles
        .expand((console) => console.emulators)
        .singleWhere((emulator) => emulator.id == 'ryubing_pc');
    expect(ryubing.sourceType, 'forgejo');
    expect(
      ryubing.downloadUrl,
      'https://git.ryujinx.app/projects/Ryubing/releases',
    );
    expect(
      ryubing.nightlyUrl,
      'https://git.ryujinx.app/Ryubing/Canary/releases',
    );

    // 本轮从官方 Releases 页面确认存在 prerelease/nightly 的项目。
    // 防止后续目录整理时误删对应渠道，导致列表只剩稳定版。
    const auditedDevelopmentIds = {
      'cemu_pc',
      'whittyarcade_pc',
      'dosbox_staging_pc',
      'padforge',
      'mupen64plus_ae',
      'rpcs3_android',
      'ruffle_android',
      'coffee_gb_pc',
      'duckstation_gpl',
      'gamenative',
      'xenios',
      'rpcs3_pc',
    };
    const auditedNightlyIds = {
      'ares_pc',
      'bsnes_pc',
      'cxbx_r',
      'virtual_jaguar_core',
      'pcsx2_pc',
      'ruffle_pc',
      'ymir_pc',
    };
    final allEmulators = config.consoles
        .expand((console) => console.emulators)
        .toList();
    for (final id in auditedDevelopmentIds) {
      expect(
        allEmulators.singleWhere((emulator) => emulator.id == id).devUrl,
        isNotEmpty,
        reason: id,
      );
    }
    for (final id in auditedNightlyIds) {
      expect(
        allEmulators.singleWhere((emulator) => emulator.id == id).nightlyUrl,
        isNotEmpty,
        reason: id,
      );
    }

    final rpcs3 = allEmulators.singleWhere(
      (emulator) => emulator.id == 'rpcs3_pc',
    );
    expect(rpcs3.devUrl, 'https://rpcs3.net/download');
    expect(rpcs3.nightlyUrl, 'https://rpcs3.net/builds');

    // 运行平台以官方 README 与当前 Release 构建资产为依据。对同时发布
    // APK 和桌面包的项目保留全部平台，防止 Windows/Linux/macOS 标签
    // 在目录维护时再次退化成仅 Android。
    const auditedPlatformLabels = <String, Set<String>>{
      'eden': {'android', 'windows', 'linux', 'macos'},
      'citron_neo': {'android', 'windows', 'linux', 'macos'},
      'armsx1': {'android', 'windows', 'linux', 'macos'},
      'armsx2': {'android', 'windows', 'linux', 'macos'},
      'azahar_plus': {'android', 'windows', 'linux'},
      'gearsystem': {'android', 'windows', 'linux', 'macos'},
      'kytyps5_pc': {'windows', 'linux', 'macos'},
      'firebird': {'android', 'windows', 'linux', 'macos'},
      'ymir_pc': {'windows', 'linux', 'macos'},
      'duckstation_gpl': {'android', 'windows', 'linux', 'macos'},
      'vita3k_plus': {'android', 'windows'},
      'vita3k_pc': {'android', 'windows', 'linux', 'macos'},
      'xenios': {'macos'},
    };
    for (final entry in auditedPlatformLabels.entries) {
      final emulator = allEmulators.singleWhere(
        (emulator) => emulator.id == entry.key,
      );
      expect(emulator.platforms.toSet(), entry.value, reason: entry.key);
    }

    expect(consoleIds.length, 120);
    expect(emulatorIds.length, 320);

    final bachataS4 = config.consoles
        .singleWhere((console) => console.id == 'ps4')
        .emulators
        .singleWhere((emulator) => emulator.id == 'bachata_s4');
    expect(bachataS4.sourceType, 'github');
    expect(
      bachataS4.sourceUrl,
      'https://github.com/JICA98/Bachata-S4',
    );
    expect(bachataS4.playStoreId, 'com.bachatas4.android');
    expect(bachataS4.minAndroid, '12.0');
    expect(bachataS4.platforms, ['android']);
    final bachataS4Icon = await rootBundle.load(bachataS4.iconPath);
    expect(bachataS4Icon.lengthInBytes, greaterThan(0));

    // melonDualDS 在 0.7.0 正式更名为 WatermelonDS。保留原 id 可避免
    // 已有收藏和版本缓存丢失，但所有用户可见信息必须指向新项目身份。
    final watermelonDS = config.consoles
        .singleWhere((console) => console.id == 'nds')
        .emulators
        .singleWhere((emulator) => emulator.id == 'melondualds');
    expect(watermelonDS.name, 'WatermelonDS');
    expect(
      watermelonDS.sourceUrl,
      'https://github.com/SapphireRhodonite/WatermelonDS',
    );
    expect(
      watermelonDS.downloadUrl,
      'https://github.com/SapphireRhodonite/WatermelonDS/releases',
    );
    expect(watermelonDS.minAndroid, '7.0');
    expect(watermelonDS.platforms, ['android']);
    final watermelonDSIcon = await rootBundle.load(watermelonDS.iconPath);
    expect(watermelonDSIcon.lengthInBytes, greaterThan(0));

    final vita3kPlus = config.consoles
        .singleWhere((console) => console.id == 'psvita')
        .emulators
        .singleWhere((emulator) => emulator.id == 'vita3k_plus');
    expect(vita3kPlus.name, 'Vita3K+');
    expect(vita3kPlus.openSource, isTrue);
    expect(vita3kPlus.sourceType, 'github');
    expect(
      vita3kPlus.sourceUrl,
      'https://github.com/nckstwrt/Vita3K-Plus',
    );
    expect(
      vita3kPlus.downloadUrl,
      'https://github.com/nckstwrt/Vita3K-Plus/releases',
    );
    expect(vita3kPlus.core, 'Vita3K');
    expect(vita3kPlus.compatibility, 'medium');
    expect(vita3kPlus.minAndroid, '9.0');
    expect(vita3kPlus.platforms, ['android', 'windows']);
    final vita3kPlusIcon = await rootBundle.load(vita3kPlus.iconPath);
    expect(vita3kPlusIcon.lengthInBytes, greaterThan(0));

    final armsx3 = config.consoles
        .singleWhere((console) => console.id == 'ps3')
        .emulators
        .singleWhere((emulator) => emulator.id == 'armsx3');
    expect(armsx3.sourceType, 'github');
    expect(armsx3.sourceUrl, 'https://github.com/ARMSX2/ARMSX3');
    expect(armsx3.downloadUrl, 'https://github.com/ARMSX2/ARMSX3/releases');
    expect(armsx3.core, 'RPCS3');
    expect(armsx3.compatibility, 'low');
    expect(armsx3.minAndroid, '10.0');
    expect(armsx3.platforms, ['android']);
    final armsx3Icon = await rootBundle.load(armsx3.iconPath);
    expect(armsx3Icon.lengthInBytes, greaterThan(0));

    final xenraOg = config.consoles
        .singleWhere((console) => console.id == 'xbox')
        .emulators
        .singleWhere((emulator) => emulator.id == 'xenra_og');
    final xenra360 = config.consoles
        .singleWhere((console) => console.id == 'xbox_360')
        .emulators
        .singleWhere((emulator) => emulator.id == 'xenra_360');
    for (final xenra in [xenraOg, xenra360]) {
      expect(xenra.name, 'Xenra');
      expect(xenra.openSource, isTrue);
      expect(xenra.sourceType, 'github');
      expect(xenra.sourceUrl, 'https://github.com/Yebot32/xenra');
      expect(
        xenra.downloadUrl,
        'https://github.com/Yebot32/xenra/releases',
      );
      expect(xenra.core, 'x1 box / XenDroid');
      expect(xenra.compatibility, 'low');
      expect(xenra.minAndroid, '10.0');
      expect(xenra.platforms, ['android']);
      final xenraIcon = await rootBundle.load(xenra.iconPath);
      expect(xenraIcon.lengthInBytes, greaterThan(0));
    }

    final purpleTurnip = config.consoles
        .singleWhere((console) => console.id == 'gpu_drivers')
        .emulators
        .singleWhere((emulator) => emulator.id == 'purple_turnip');
    expect(
      purpleTurnip.sourceUrl,
      'https://github.com/MrPurple666/purple-turnip',
    );
    expect(
      purpleTurnip.downloadUrl,
      'https://github.com/MrPurple666/purple-turnip/releases/latest',
    );
    expect(purpleTurnip.minAndroid, '11.0');
    expect(purpleTurnip.platforms, ['android']);
    final purpleTurnipIcon = await rootBundle.load(purpleTurnip.iconPath);
    expect(purpleTurnipIcon.lengthInBytes, greaterThan(0));

    final whitebelyashTurnip = config.consoles
        .singleWhere((console) => console.id == 'gpu_drivers')
        .emulators
        .singleWhere((emulator) => emulator.id == 'whitebelyash_turnip');
    expect(
      whitebelyashTurnip.sourceUrl,
      'https://github.com/whitebelyash/AdrenoToolsDrivers',
    );
    expect(
      whitebelyashTurnip.downloadUrl,
      'https://github.com/whitebelyash/AdrenoToolsDrivers/releases',
    );
    expect(whitebelyashTurnip.core, 'Mesa Turnip / Freedreno');
    expect(whitebelyashTurnip.compatibility, 'medium');
    expect(whitebelyashTurnip.minAndroid, '10.0');
    expect(whitebelyashTurnip.platforms, ['android']);
    final whitebelyashTurnipIcon =
        await rootBundle.load(whitebelyashTurnip.iconPath);
    expect(whitebelyashTurnipIcon.lengthInBytes, greaterThan(0));

    final swiff = config.consoles
        .singleWhere((console) => console.id == 'flash')
        .emulators
        .singleWhere((emulator) => emulator.id == 'swiff');
    expect(swiff.openSource, isFalse);
    expect(swiff.sourceType, 'github');
    expect(swiff.sourceUrl, 'https://github.com/NaviVani-dev/Swiff');
    expect(swiff.downloadUrl, 'https://github.com/NaviVani-dev/Swiff/releases');
    expect(swiff.core, 'Ruffle / AwayFL');
    expect(swiff.minAndroid, '8.0');
    expect(swiff.platforms, ['android']);
    final swiffIcon = await rootBundle.load(swiff.iconPath);
    expect(swiffIcon.lengthInBytes, greaterThan(0));

    final winNative = config.consoles
        .singleWhere((console) => console.id == 'dos')
        .emulators
        .singleWhere((emulator) => emulator.id == 'winnative');
    expect(winNative.openSource, isTrue);
    expect(winNative.sourceType, 'github');
    expect(
      winNative.sourceUrl,
      'https://github.com/WinNative-Emu/WinNative',
    );
    expect(
      winNative.downloadUrl,
      'https://github.com/WinNative-Emu/WinNative/releases',
    );
    expect(winNative.core, 'Wine / Box64 / FEX');
    expect(winNative.compatibility, 'medium');
    expect(winNative.minAndroid, '8.0');
    expect(winNative.platforms, ['android']);
    final winNativeIcon = await rootBundle.load(winNative.iconPath);
    expect(winNativeIcon.lengthInBytes, greaterThan(0));

    final netherSx2Lsfg = config.consoles
        .singleWhere((console) => console.id == 'ps2')
        .emulators
        .singleWhere((emulator) => emulator.id == 'nethersx2_lsfg');
    expect(netherSx2Lsfg.openSource, isFalse);
    expect(netherSx2Lsfg.sourceType, 'github');
    expect(
      netherSx2Lsfg.sourceUrl,
      'https://github.com/slushiimusic/NetherSX2-Slushii-Turnip-Fix',
    );
    expect(netherSx2Lsfg.core, 'AetherSX2 4248 / LSFG');
    expect(netherSx2Lsfg.compatibility, 'medium');
    expect(netherSx2Lsfg.minAndroid, '8.0');
    expect(netherSx2Lsfg.platforms, ['android']);
    final netherSx2LsfgIcon = await rootBundle.load(netherSx2Lsfg.iconPath);
    expect(netherSx2LsfgIcon.lengthInBytes, greaterThan(0));

    final winlator = config.consoles
        .singleWhere((console) => console.id == 'dos')
        .emulators
        .singleWhere((emulator) => emulator.id == 'winlator');
    expect(winlator.openSource, isTrue);
    expect(winlator.sourceType, 'github');
    expect(winlator.sourceUrl, 'https://github.com/brunodev85/winlator');
    expect(winlator.core, 'Wine / Box86 / Box64');
    expect(winlator.compatibility, 'high');
    expect(winlator.minAndroid, '8.0');
    expect(winlator.platforms, ['android']);
    final winlatorIcon = await rootBundle.load(winlator.iconPath);
    expect(winlatorIcon.lengthInBytes, greaterThan(0));

    final joiPlay = config.consoles
        .singleWhere((console) => console.id == 'rpgmaker')
        .emulators
        .singleWhere((emulator) => emulator.id == 'joiplay');
    expect(joiPlay.openSource, isFalse);
    expect(joiPlay.sourceType, 'website');
    expect(
      joiPlay.sourceUrl,
      'https://joiplay.net/assets/json/downloads.json',
    );
    expect(joiPlay.website, 'https://joiplay.net/');
    expect(joiPlay.core, 'RPG Maker / Ren\'Py / Ruffle / Godot');
    expect(joiPlay.minAndroid, '5.0');
    expect(joiPlay.platforms, ['android']);
    final joiPlayIcon = await rootBundle.load(joiPlay.iconPath);
    expect(joiPlayIcon.lengthInBytes, greaterThan(0));

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
        'nesd',
        'gearboy_pc',
        'luna_project64_pc',
        'nexium_pc',
        'ngpcraft_pc',
        'copperline_pc',
        'winuae_pc',
        'hbmame_pc',
        'kat5200',
        'winarcadia_pc',
        'gameex',
        'pinballx',
        'gse_speedrun',
        'panda3ds',
        'pcsx2x6_arcade',
        'supermodel_ponmi',
        'negamame_pc',
        'pcbox_pc',
        'xenia_edge_pc',
        'pcfxemu_pc',
        's4w_scanlines',
        'romvault',
        'xenia_manager',
        'gameplay_frontend',
        'bachata_s4',
        'armsx3',
        'whitebelyash_turnip',
        'swiff',
        'winnative',
        'nethersx2_lsfg',
        'winlator',
        'joiplay',
        'vita3k_plus',
        'xenra_og',
        'xenra_360',
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
