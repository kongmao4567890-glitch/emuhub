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

    expect(consoleIds.length, 117);
    expect(emulatorIds.length, 228);
  });
}
