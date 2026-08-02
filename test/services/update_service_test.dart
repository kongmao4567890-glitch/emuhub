import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:emuhub/data/database/database.dart';
import 'package:emuhub/data/models/emulator.dart';
import 'package:emuhub/data/models/version_info.dart';
import 'package:emuhub/services/update/update_service.dart';
import 'package:emuhub/services/update/version_adapter.dart';

void main() {
  late AppDatabase database;
  late _MutableAdapter adapter;
  late UpdateService service;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    adapter = _MutableAdapter();
    service = UpdateService(
      dao: database.cachedVersionsDao,
      githubAdapter: adapter,
      websiteAdapter: adapter,
      requestDelay: Duration.zero,
    );
  });

  tearDown(() => database.close());

  test('preserves unread updates until they are explicitly marked as seen',
      () async {
    final emulator = _emulator('emu-a');

    adapter.version = '1.0.0';
    final baseline = await service.checkOne(emulator);
    expect(baseline?.isNew, isFalse);

    adapter.version = '1.1.0';
    final update = await service.checkOne(emulator);
    expect(update?.isNew, isTrue);

    // A repeated check of the same remote version must not clear the unread flag
    // or report a newly detected update again.
    final repeated = await service.checkAll([emulator]);
    expect(repeated.updated, isEmpty);
    expect(
      (await database.cachedVersionsDao.getCachedVersion(emulator.id))?.isNew,
      isTrue,
    );

    await database.cachedVersionsDao.markAsSeen(emulator.id);
    final afterSeen = await service.checkOne(emulator);
    expect(afterSeen?.isNew, isFalse);
  });

  test('does not downgrade the cache when a source temporarily returns older data',
      () async {
    final emulator = _emulator('emu-a');

    adapter.version = '2.0.0';
    await service.checkOne(emulator);
    adapter.version = '1.9.0';

    final result = await service.checkOne(emulator);
    final cached =
        await database.cachedVersionsDao.getCachedVersion(emulator.id);

    expect(result?.version, '2.0.0');
    expect(cached?.currentVersion, '2.0.0');
  });

  test('deduplicates identical network sources during a batch check', () async {
    final first = _emulator('emu-a');
    final second = _emulator('emu-b');
    adapter.version = '1.0.0';

    final result = await service.checkAll([first, second]);

    expect(result.checked, 2);
    expect(adapter.calls, 1);
    expect(
      await database.cachedVersionsDao.getCachedVersion(first.id),
      isNotNull,
    );
    expect(
      await database.cachedVersionsDao.getCachedVersion(second.id),
      isNotNull,
    );
  });

  test('does not use check time as release date and fills details on entry',
      () async {
    final emulator = _emulator('emu-a');

    await service.checkAll([emulator]);
    var cached =
        await database.cachedVersionsDao.getCachedVersion(emulator.id);
    expect(cached?.lastReleaseDate, isNull);

    await service.checkOne(emulator);
    cached = await database.cachedVersionsDao.getCachedVersion(emulator.id);
    expect(
      cached?.lastReleaseDate,
      DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
    );
  });
}

class _MutableAdapter implements VersionAdapter {
  String version = '1.0.0';
  int calls = 0;

  @override
  String get adapterName => 'github';

  @override
  Future<VersionInfo?> fetchLatestVersion(
    Emulator emulator, {
    bool includeDetails = false,
  }) async {
    calls++;
    return VersionInfo(
      emulatorId: emulator.id,
      version: version,
      releaseDate: includeDetails ? DateTime.utc(2026, 1, 1) : null,
      releaseNotes: 'notes for $version',
      isNew: false,
      downloadUrl: 'https://example.com/$version.apk',
    );
  }
}

Emulator _emulator(String id) {
  return Emulator(
    id: id,
    name: id,
    openSource: true,
    sourceType: 'github',
    sourceUrl: 'https://github.com/example/shared',
    playStoreId: '',
    website: '',
    core: 'core',
    compatibility: 'good',
    minAndroid: '8.0',
    description: 'test emulator',
    downloadUrl: 'https://example.com/latest.apk',
  );
}
