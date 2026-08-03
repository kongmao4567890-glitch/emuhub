import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:emuhub/data/models/emulator.dart';
import 'package:emuhub/services/update/github_adapter.dart';

void main() {
  test('tracks prerelease nightly when only nightlyUrl is configured',
      () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final path = options.uri.path;
          if (options.method == 'HEAD' && path.endsWith('/releases/latest')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 302,
                headers: Headers.fromMap({
                  'location': [
                    'https://github.com/ARMSX2/ARMSX2/releases/tag/iOSv2.5.1',
                  ],
                }),
              ),
            );
            return;
          }
          if (path.endsWith('/releases')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '<a href="/ARMSX2/ARMSX2/releases/tag/nightly-20260802">'
                    'nightly</a><span>Pre-release</span>',
              ),
            );
            return;
          }
          if (path.contains('/expanded_assets/nightly-20260802')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '<a href="/ARMSX2/ARMSX2/releases/download/nightly-20260802/'
                    'ARMSX2-nightly-20260802.apk">APK</a>',
              ),
            );
            return;
          }
          if (path.endsWith('/releases/tag/nightly-20260802')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '<relative-time datetime="2026-08-02T00:00:00Z"></relative-time>'
                    '<div class="markdown-body">Nightly fixes</div>',
              ),
            );
            return;
          }
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
            ),
          );
        },
      ),
    );

    final result = await GitHubReleasesAdapter(dio: dio).fetchLatestVersion(
      _armsx2(),
    );

    expect(result?.version, 'nightly-20260802');
    expect(result?.releaseNotes, 'Nightly fixes');
    expect(
      result?.downloadUrl,
      'https://github.com/ARMSX2/ARMSX2/releases/download/nightly-20260802/'
      'ARMSX2-nightly-20260802.apk',
    );
  });
}

Emulator _armsx2() {
  return const Emulator(
    id: 'armsx2',
    name: 'ARMSX2',
    openSource: true,
    sourceType: 'github',
    sourceUrl: 'https://github.com/ARMSX2/ARMSX2',
    playStoreId: '',
    website: 'https://armsx2.com/',
    core: '',
    compatibility: 'high',
    minAndroid: '8.0',
    description: 'test',
    downloadUrl: 'https://github.com/ARMSX2/ARMSX2/releases',
    nightlyUrl: 'https://github.com/ARMSX2/ARMSX2/releases',
  );
}
