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
      retryDelay: Duration.zero,
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
    // 两个相同来源共享一次轻量请求和一次完整详情请求。
    expect(adapter.calls, 2);
    expect(adapter.detailCalls, 1);
    expect(
      await database.cachedVersionsDao.getCachedVersion(first.id),
      isNotNull,
    );
    expect(
      await database.cachedVersionsDao.getCachedVersion(second.id),
      isNotNull,
    );
  });

  test('batch update check stores complete release metadata',
      () async {
    final emulator = _emulator('emu-a');

    await service.checkAll([emulator]);
    final cached =
        await database.cachedVersionsDao.getCachedVersion(emulator.id);
    expect(
      cached?.lastReleaseDate,
      DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
    );
    expect(cached?.releaseNotes, 'notes for 1.0.0');
    expect(cached?.resolvedDownloadUrl, 'https://example.com/1.0.0.apk');
  });

  test('retries a transient source failure within the same batch check',
      () async {
    final emulator = _emulator('emu-a');
    adapter.remainingFailures = 1;

    final result = await service.checkAll([emulator]);

    expect(result.checked, 1);
    expect(result.failed, isEmpty);
    expect(await database.cachedVersionsDao.getCachedVersion(emulator.id),
        isNotNull);
    // 首次轻量请求失败后自动重试成功，随后再抓一次完整详情。
    expect(adapter.calls, 3);
  });

  test('merges Play metadata with the website fallback version', () async {
    final playAdapter = _PlayMetadataAdapter();
    final websiteAdapter = _WebsiteVersionAdapter();
    final playService = UpdateService(
      dao: database.cachedVersionsDao,
      playStoreAdapter: playAdapter,
      websiteAdapter: websiteAdapter,
      requestDelay: Duration.zero,
      retryDelay: Duration.zero,
    );
    final emulator = _playStoreEmulator('epsxe');

    final result = await playService.checkOne(emulator);
    final cached =
        await database.cachedVersionsDao.getCachedVersion(emulator.id);

    expect(result?.version, '1.6.4');
    expect(result?.releaseDate, DateTime.utc(2026, 7, 10));
    expect(result?.releaseNotes, 'Play Store release notes');
    expect(cached?.currentVersion, '1.6.4');
    expect(cached?.releaseNotes, 'Play Store release notes');
  });
}

class _MutableAdapter implements VersionAdapter {
  String version = '1.0.0';
  int calls = 0;
  int detailCalls = 0;
  int remainingFailures = 0;

  @override
  String get adapterName => 'github';

  @override
  Future<VersionInfo?> fetchLatestVersion(
    Emulator emulator, {
    bool includeDetails = false,
  }) async {
    calls++;
    if (remainingFailures > 0) {
      remainingFailures--;
      return null;
    }
    if (includeDetails) detailCalls++;
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

class _PlayMetadataAdapter implements VersionAdapter {
  @override
  String get adapterName => 'playstore';

  @override
  Future<VersionInfo?> fetchLatestVersion(
    Emulator emulator, {
    bool includeDetails = false,
  }) async {
    return VersionInfo(
      emulatorId: emulator.id,
      version: '',
      releaseDate: DateTime.utc(2026, 7, 10),
      releaseNotes: 'Play Store release notes',
      isNew: false,
    );
  }
}

class _WebsiteVersionAdapter implements VersionAdapter {
  @override
  String get adapterName => 'website';

  @override
  Future<VersionInfo?> fetchLatestVersion(
    Emulator emulator, {
    bool includeDetails = false,
  }) async {
    return VersionInfo(
      emulatorId: emulator.id,
      version: '1.6.4',
      releaseDate: null,
      releaseNotes: null,
      isNew: false,
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

Emulator _playStoreEmulator(String id) {
  return Emulator(
    id: id,
    name: id,
    openSource: false,
    sourceType: 'playstore',
    sourceUrl: '',
    playStoreId: 'com.epsxe.ePSXe',
    website: 'https://www.epsxe.com/android/',
    core: '',
    compatibility: 'high',
    minAndroid: '5.0',
    description: 'test emulator',
    downloadUrl:
        'https://play.google.com/store/apps/details?id=com.epsxe.ePSXe',
  );
}
