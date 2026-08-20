import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:emuhub/data/models/emulator.dart';
import 'package:emuhub/services/update/website_adapter.dart';

void main() {
  test('prefers a machine-readable source URL over the public website',
      () async {
    final requestedUrls = <String>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestedUrls.add(options.uri.toString());
          handler.resolve(
            Response<String>(
              requestOptions: options,
              statusCode: 200,
              data: '[{"title":"JoiPlay","version":"1.21.000"}]',
            ),
          );
        },
      ),
    );

    final result = await WebsiteAdapter(dio: dio).fetchLatestVersion(
      _websiteEmulator(
        sourceUrl: 'https://example.com/downloads.json',
        website: 'https://example.com/',
      ),
    );

    expect(requestedUrls, ['https://example.com/downloads.json']);
    expect(result?.version, '1.21.000');
  });

  test('falls back to the public website when source URL is empty', () async {
    final requestedUrls = <String>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestedUrls.add(options.uri.toString());
          handler.resolve(
            Response<String>(
              requestOptions: options,
              statusCode: 200,
              data: '<p>Version 2.4.0</p>',
            ),
          );
        },
      ),
    );

    final result = await WebsiteAdapter(dio: dio).fetchLatestVersion(
      _websiteEmulator(
        sourceUrl: '',
        website: 'https://example.com/releases',
      ),
    );

    expect(requestedUrls, ['https://example.com/releases']);
    expect(result?.version, '2.4.0');
  });
}

Emulator _websiteEmulator({
  required String sourceUrl,
  required String website,
}) {
  return Emulator(
    id: 'website-test',
    name: 'Website Test',
    openSource: false,
    sourceType: 'website',
    sourceUrl: sourceUrl,
    playStoreId: '',
    website: website,
    core: '',
    compatibility: 'good',
    minAndroid: '5.0',
    description: 'test',
  );
}
