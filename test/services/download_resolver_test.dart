import 'package:flutter_test/flutter_test.dart';

import 'package:emuhub/data/models/emulator.dart';
import 'package:emuhub/services/download/download_resolver.dart';

void main() {
  test('prefers a dynamically resolved download URL', () {
    final emulator = _emulator(
      'https://example.com/v1.0.0/emulator-v1.0.0.apk',
    );

    expect(
      DownloadResolver.resolveStableUrl(
        emulator,
        cachedDownloadUrl: 'https://example.com/current.apk',
        latestVersion: '2.0.0',
      ),
      'https://example.com/current.apk',
    );
  });

  test('updates all version occurrences in a versioned URL', () {
    final emulator = _emulator(
      'https://example.com/v1.0.0/emulator-v1.0.0.apk',
    );

    expect(
      DownloadResolver.resolveStableUrl(
        emulator,
        latestVersion: '2.1.0',
      ),
      'https://example.com/v2.1.0/emulator-v2.1.0.apk',
    );
  });

  test('classifies versioned assets as volatile', () {
    expect(
      DownloadResolver.isUrlVolatile(
        'https://github.com/example/app/releases/latest/download/app-1.2.3.apk',
      ),
      isTrue,
    );
    expect(
      DownloadResolver.isUrlVolatile(
        'https://github.com/example/app/releases/latest/download/app.apk',
      ),
      isFalse,
    );
  });

  test('does not duplicate a nightly asset as a development channel', () {
    final emulator = _emulator('https://example.com/releases').copyWith(
      nightlyUrl: 'https://example.com/nightly',
    );

    expect(
      DownloadResolver.resolveDevUrl(
        emulator,
        cachedDevDownloadUrl: 'https://example.com/nightly.apk',
      ),
      isEmpty,
    );
  });
}

Emulator _emulator(String downloadUrl) {
  return Emulator(
    id: 'emulator',
    name: 'Emulator',
    openSource: true,
    sourceType: 'website',
    sourceUrl: '',
    playStoreId: '',
    website: 'https://example.com',
    core: 'core',
    compatibility: 'good',
    minAndroid: '8.0',
    description: 'test emulator',
    downloadUrl: downloadUrl,
  );
}
