import 'package:flutter_test/flutter_test.dart';

import 'package:emuhub/data/models/emulator.dart';
import 'package:emuhub/services/update/version_catalog_service.dart';

void main() {
  test('returns the release selected by the generated catalog', () async {
    var loads = 0;
    final service = VersionCatalogService(
      loader: () async {
        loads++;
        return <String, dynamic>{
          'generatedAt': '2026-08-16T01:00:00Z',
          'entries': <String, dynamic>{
            'armsx3': <String, dynamic>{
              'version': '0.8',
              'releaseDate': '2026-08-15T23:30:00Z',
              'releaseNotes': 'Latest by publication time',
              'downloadUrl': 'https://example.com/armsx3.apk',
            },
          },
        };
      },
    );

    final first = await service.lookup(_emulator('armsx3'));
    final second = await service.lookup(_emulator('armsx3'));

    expect(first?.version, '0.8');
    expect(first?.releaseDate, DateTime.utc(2026, 8, 15, 23, 30));
    expect(first?.releaseNotes, 'Latest by publication time');
    expect(first?.downloadUrl, 'https://example.com/armsx3.apk');
    expect(second?.version, '0.8');
    expect(loads, 1, reason: 'all emulator lookups share one catalog load');
  });

  test('returns null for an emulator absent from the catalog', () async {
    final service = VersionCatalogService(
      loader: () async => <String, dynamic>{'entries': <String, dynamic>{}},
    );

    expect(await service.lookup(_emulator('missing')), isNull);
  });
}

Emulator _emulator(String id) => Emulator(
      id: id,
      name: id,
      openSource: true,
      sourceType: 'github',
      sourceUrl: 'https://github.com/example/$id',
      playStoreId: '',
      website: '',
      core: 'RPCS3',
      compatibility: 'low',
      minAndroid: '10',
      description: 'test',
    );
