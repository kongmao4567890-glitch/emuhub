import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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

    expect(consoleIds.length, 117);
    expect(emulatorIds.length, 234);
  });
}
