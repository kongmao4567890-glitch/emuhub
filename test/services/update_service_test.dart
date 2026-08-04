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
    adapter.releaseDate = DateTime.utc(2026, 1, 2);
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

  test('uses publication time for incomparable nightly and stable versions',
      () async {
    final emulator = _emulator('armsx2').copyWith(
      nightlyUrl: 'https://github.com/example/armsx2/releases',
    );

    adapter.version = 'nightly-20260803';
    adapter.releaseDate = DateTime.utc(2026, 8, 3, 12);
    await service.checkOne(emulator);
    adapter.version = '2.6.6.3';
    adapter.releaseDate = DateTime.utc(2026, 8, 3, 13);

    final result = await service.checkAll([emulator]);
    final cached =
        await database.cachedVersionsDao.getCachedVersion(emulator.id);

    expect(result.updated.single.version, '2.6.6.3');
    expect(cached?.currentVersion, '2.6.6.3');
    expect(cached?.releaseNotes, 'notes for 2.6.6.3');
  });

  test('repairs a missing-date cache without reporting a new update',
      () async {
    final emulator = _emulator('x360-mobile').copyWith(
      devUrl: 'https://github.com/example/x360/releases',
    );
    await database.cachedVersionsDao.upsertFromVersionInfo(
      const VersionInfo(
        emulatorId: 'x360-mobile',
        version: '1.0',
        isNew: false,
      ),
    );
    adapter.version = '0.5.3_preview';
    adapter.releaseDate = DateTime.utc(2026, 6, 7, 13, 23, 24);

    final result = await service.checkAll([emulator]);
    final cached =
        await database.cachedVersionsDao.getCachedVersion(emulator.id);

    expect(result.updated, isEmpty);
    expect(cached?.currentVersion, '0.5.3_preview');
    expect(cached?.releaseNotes, 'notes for 0.5.3_preview');
    expect(cached?.isNew, isFalse);
  });

  test('repairs a legacy check-time release date without reporting an update',
      () async {
    final emulator = _emulator('legacy-check-date');
    await database.cachedVersionsDao.upsertFromVersionInfo(
      VersionInfo(
        emulatorId: emulator.id,
        version: '1.0',
        releaseDate: DateTime.now(),
        isNew: true,
      ),
    );
    adapter.version = '0.5.3_preview';
    adapter.releaseDate = DateTime.utc(2026, 6, 7, 13, 23, 24);

    final result = await service.checkAll([emulator]);
    final cached =
        await database.cachedVersionsDao.getCachedVersion(emulator.id);

    expect(result.updated, isEmpty);
    expect(cached?.currentVersion, '0.5.3_preview');
    expect(
      cached?.lastReleaseDate,
      DateTime.utc(2026, 6, 7, 13, 23, 24).millisecondsSinceEpoch,
    );
    // 未读状态由数据库升级迁移统一清理；本测试只验证
    // 可疑日期不再阻止真实元数据回写。
    expect(cached?.isNew, isTrue);
  });

  test('does not report an update when only the version changes', () async {
    final emulator = _emulator('same-date-version');

    adapter.version = '1.0.0';
    adapter.releaseDate = DateTime.utc(2026, 2, 1);
    await service.checkOne(emulator);
    adapter.version = '2.0.0';

    final result = await service.checkAll([emulator]);
    final cached =
        await database.cachedVersionsDao.getCachedVersion(emulator.id);

    expect(result.updated, isEmpty);
    expect(cached?.currentVersion, '2.0.0');
    expect(cached?.isNew, isFalse);
  });

  test('does not cache an unrelated website version when GitHub is unavailable',
      () async {
    final protectedService = UpdateService(
      dao: database.cachedVersionsDao,
      githubAdapter: _UnavailableGitHubAdapter(),
      websiteAdapter: _WebsiteVersionAdapter(),
      requestDelay: Duration.zero,
      retryDelay: Duration.zero,
    );
    final emulator = _emulator('github-fallback').copyWith(
      website: 'https://example.com/product',
      downloadUrl: 'https://example.com/latest.apk',
    );

    final result = await protectedService.checkOne(emulator);

    expect(result, isNull);
    expect(await database.cachedVersionsDao.getCachedVersion(emulator.id),
        isNull);
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

  test('processes independent sources with the configured concurrency',
      () async {
    final concurrentAdapter = _ConcurrencyAdapter();
    final fastService = UpdateService(
      dao: database.cachedVersionsDao,
      githubAdapter: concurrentAdapter,
      websiteAdapter: concurrentAdapter,
      maxConcurrency: 10,
      requestDelay: Duration.zero,
      retryDelay: Duration.zero,
    );
    final emulators = List.generate(
      20,
      (index) => _emulator('fast-$index').copyWith(
        sourceUrl: 'https://github.com/example/fast-$index',
      ),
    );

    final result = await fastService.checkAll(emulators);

    expect(result.checked, 20);
    expect(concurrentAdapter.maxInFlight, 10);
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

  test('supplements a GitHub-sourced emulator with Play Store metadata',
      () async {
    final githubAdapter = _WebsiteVersionAdapter();
    final playAdapter = _PlayMetadataAdapter();
    final playService = UpdateService(
      dao: database.cachedVersionsDao,
      githubAdapter: githubAdapter,
      playStoreAdapter: playAdapter,
      requestDelay: Duration.zero,
      retryDelay: Duration.zero,
    );
    final emulator = _githubEmulatorWithPlayStore('retroarch');

    final result = await playService.checkOne(emulator);
    final cached =
        await database.cachedVersionsDao.getCachedVersion(emulator.id);

    expect(result?.version, '1.6.4');
    expect(result?.releaseDate, DateTime.utc(2026, 7, 10));
    expect(result?.releaseNotes, 'Play Store release notes');
    expect(cached?.releaseNotes, 'Play Store release notes');
  });

  test('keeps newer primary metadata when Play Store is older', () async {
    final githubAdapter = _DatedWebsiteAdapter(DateTime.utc(2026, 8, 1));
    final playAdapter = _PlayMetadataAdapter();
    final playService = UpdateService(
      dao: database.cachedVersionsDao,
      githubAdapter: githubAdapter,
      playStoreAdapter: playAdapter,
      requestDelay: Duration.zero,
      retryDelay: Duration.zero,
    );
    final emulator = _githubEmulatorWithPlayStore('dated-primary');

    final result = await playService.checkOne(emulator);

    expect(result?.releaseDate, DateTime.utc(2026, 8, 1));
    expect(result?.releaseNotes, 'Primary release notes');
  });

  test('shares Play Store metadata requests for matching package ids',
      () async {
    final githubAdapter = _WebsiteVersionAdapter();
    final playAdapter = _CountingPlayMetadataAdapter();
    final playService = UpdateService(
      dao: database.cachedVersionsDao,
      githubAdapter: githubAdapter,
      playStoreAdapter: playAdapter,
      requestDelay: Duration.zero,
      retryDelay: Duration.zero,
    );
    final first = _githubEmulatorWithPlayStore('md-emu');
    final second = _githubEmulatorWithPlayStore('md-emu-sms');

    final result = await playService.checkAll([first, second]);

    expect(result.checked, 2);
    expect(playAdapter.calls, 1);
    expect(
      (await database.cachedVersionsDao.getCachedVersion(first.id))
          ?.releaseNotes,
      'Play Store release notes',
    );
    expect(
      (await database.cachedVersionsDao.getCachedVersion(second.id))
          ?.releaseNotes,
      'Play Store release notes',
    );
  });

  test('stores Play metadata even when no source exposes a version',
      () async {
    final playService = UpdateService(
      dao: database.cachedVersionsDao,
      playStoreAdapter: _PlayMetadataAdapter(),
      websiteAdapter: _UnavailableAdapter(),
      requestDelay: Duration.zero,
      retryDelay: Duration.zero,
    );
    final emulator = _playStoreEmulator('my-boy').copyWith(website: '');

    final result = await playService.checkOne(emulator);
    final cached =
        await database.cachedVersionsDao.getCachedVersion(emulator.id);

    expect(result, isNotNull);
    expect(result?.version, isEmpty);
    expect(result?.releaseDate, DateTime.utc(2026, 7, 10));
    expect(result?.releaseNotes, 'Play Store release notes');
    expect(cached, isNotNull);
    expect(cached?.currentVersion, isEmpty);
    expect(cached?.releaseNotes, 'Play Store release notes');
  });

  test('keeps Play-only metadata when a configured primary source fails',
      () async {
    final playService = UpdateService(
      dao: database.cachedVersionsDao,
      githubAdapter: _UnavailableAdapter(),
      playStoreAdapter: _PlayMetadataAdapter(),
      websiteAdapter: _UnavailableAdapter(),
      requestDelay: Duration.zero,
      retryDelay: Duration.zero,
    );
    final emulator = _githubEmulatorWithPlayStore('github-unavailable');

    final result = await playService.checkOne(emulator);
    final cached =
        await database.cachedVersionsDao.getCachedVersion(emulator.id);

    expect(result, isNotNull);
    expect(result?.version, isEmpty);
    expect(result?.releaseNotes, 'Play Store release notes');
    expect(cached?.releaseNotes, 'Play Store release notes');
  });

  test('preserves a cached version while refreshing Play metadata',
      () async {
    final playAdapter = _MutablePlayAdapter();
    final playService = UpdateService(
      dao: database.cachedVersionsDao,
      playStoreAdapter: playAdapter,
      websiteAdapter: _UnavailableAdapter(),
      requestDelay: Duration.zero,
      retryDelay: Duration.zero,
    );
    final emulator = _playStoreEmulator('play-only').copyWith(website: '');

    playAdapter.version = '2.0.0';
    await playService.checkOne(emulator);
    playAdapter.version = '';
    playAdapter.notes = 'New Play Store notes';
    final result = await playService.checkOne(emulator);
    final cached =
        await database.cachedVersionsDao.getCachedVersion(emulator.id);

    expect(result?.version, '2.0.0');
    expect(result?.releaseNotes, 'New Play Store notes');
    expect(cached?.currentVersion, '2.0.0');
    expect(cached?.releaseNotes, 'New Play Store notes');
  });
}

class _MutableAdapter implements VersionAdapter {
  String version = '1.0.0';
  DateTime releaseDate = DateTime.utc(2026, 1, 1);
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
      releaseDate: includeDetails ? releaseDate : null,
      releaseNotes: 'notes for $version',
      isNew: false,
      downloadUrl: 'https://example.com/$version.apk',
    );
  }
}

class _ConcurrencyAdapter implements VersionAdapter {
  var _inFlight = 0;
  var maxInFlight = 0;

  @override
  String get adapterName => 'github';

  @override
  Future<VersionInfo?> fetchLatestVersion(
    Emulator emulator, {
    bool includeDetails = false,
  }) async {
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    _inFlight--;
    return VersionInfo(
      emulatorId: emulator.id,
      version: '1.0.0',
      releaseDate: includeDetails ? DateTime.utc(2026, 1, 1) : null,
      releaseNotes: includeDetails ? 'fast check' : null,
      isNew: false,
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

class _CountingPlayMetadataAdapter extends _PlayMetadataAdapter {
  int calls = 0;

  @override
  Future<VersionInfo?> fetchLatestVersion(
    Emulator emulator, {
    bool includeDetails = false,
  }) async {
    calls++;
    return super.fetchLatestVersion(emulator, includeDetails: includeDetails);
  }
}

class _MutablePlayAdapter implements VersionAdapter {
  String version = '';
  String notes = 'Initial Play Store notes';

  @override
  String get adapterName => 'playstore';

  @override
  Future<VersionInfo?> fetchLatestVersion(
    Emulator emulator, {
    bool includeDetails = false,
  }) async {
    return VersionInfo(
      emulatorId: emulator.id,
      version: version,
      releaseDate: DateTime.utc(2026, 7, 10),
      releaseNotes: notes,
      isNew: false,
    );
  }
}

class _UnavailableAdapter implements VersionAdapter {
  @override
  String get adapterName => 'website';

  @override
  Future<VersionInfo?> fetchLatestVersion(
    Emulator emulator, {
    bool includeDetails = false,
  }) async =>
      null;
}

class _UnavailableGitHubAdapter extends _UnavailableAdapter {
  @override
  String get adapterName => 'github';
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

class _DatedWebsiteAdapter extends _WebsiteVersionAdapter {
  _DatedWebsiteAdapter(this.date);

  final DateTime date;

  @override
  Future<VersionInfo?> fetchLatestVersion(
    Emulator emulator, {
    bool includeDetails = false,
  }) async {
    return VersionInfo(
      emulatorId: emulator.id,
      version: '1.6.4',
      releaseDate: date,
      releaseNotes: 'Primary release notes',
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

Emulator _githubEmulatorWithPlayStore(String id) {
  return Emulator(
    id: id,
    name: id,
    openSource: true,
    sourceType: 'github',
    sourceUrl: 'https://github.com/example/$id',
    playStoreId: 'com.example.shared',
    website: '',
    core: 'core',
    compatibility: 'good',
    minAndroid: '8.0',
    description: 'test emulator',
    downloadUrl: 'https://example.com/latest.apk',
  );
}
