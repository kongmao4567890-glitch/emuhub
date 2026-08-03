import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:emuhub/data/models/emulator.dart';
import 'package:emuhub/services/update/github_adapter.dart';

void main() {
  test('uses the newer nightly release when it was published after stable',
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
          if (path.endsWith('/releases/latest')) {
            handler.resolve(
              Response<String>(
                requestOptions: RequestOptions(
                  path: 'https://github.com/ARMSX2/ARMSX2/releases/tag/'
                      'iOSv2.5.1',
                ),
                statusCode: 200,
                data: '<relative-time datetime="2026-08-01T00:00:00Z"></relative-time>'
                    '<div class="markdown-body">Stable fixes</div>',
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
    expect(result?.releaseDate, DateTime.parse('2026-08-02T00:00:00Z'));
    expect(result?.releaseNotes, 'Nightly fixes');
    expect(result?.devReleaseNotes, 'Nightly fixes');
    expect(
      result?.devDownloadUrl,
      'https://github.com/ARMSX2/ARMSX2/releases/download/nightly-20260802/'
      'ARMSX2-nightly-20260802.apk',
    );
    expect(
      result?.downloadUrl,
      'https://github.com/ARMSX2/ARMSX2/releases/download/nightly-20260802/'
      'ARMSX2-nightly-20260802.apk',
    );
  });

  test('promotes a newer prerelease when a development source is configured',
      () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final path = options.uri.path;
          final perPage = options.uri.queryParameters['per_page'];
          if (options.method == 'HEAD' && path.endsWith('/releases/latest')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 302,
                headers: Headers.fromMap({
                  'location': [
                    'https://github.com/Ashnar2602/X360-Mobile---OFFICIAL/'
                        'releases/tag/v0.5.2',
                  ],
                }),
              ),
            );
            return;
          }
          if (path.endsWith('/releases') && perPage == null) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '<a href="/Ashnar2602/X360-Mobile---OFFICIAL/releases/'
                    'tag/v0.5.3_%E9%A2%84%E8%A7%88%E7%89%88">'
                    '0.5.3 preview</a><span>Pre-release</span>',
              ),
            );
            return;
          }
          if (path.endsWith('/releases/latest')) {
            handler.resolve(
              Response<String>(
                requestOptions: RequestOptions(
                  path: 'https://github.com/Ashnar2602/'
                      'X360-Mobile---OFFICIAL/releases/tag/v0.5.2',
                ),
                statusCode: 200,
                data: '<relative-time datetime="2026-06-06T00:00:00Z"></relative-time>'
                    '<div class="markdown-body">Stable fixes</div>',
              ),
            );
            return;
          }
          if (path.contains('/expanded_assets/')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '<a href="/Ashnar2602/X360-Mobile---OFFICIAL/releases/'
                    'download/v0.5.3_%E9%A2%84%E8%A7%88%E7%89%88/'
                    'X360_0.5.3_preview.apk">APK</a>',
              ),
            );
            return;
          }
          if (path.contains('/releases/tag/')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '<relative-time datetime="2026-06-07T00:00:00Z">'
                    '</relative-time><div class="markdown-body">'
                    'X360 Mobile preview fixes</div>',
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
      _x360Mobile(),
    );

    expect(result?.version, '0.5.3_预览版');
    expect(result?.releaseDate, DateTime.parse('2026-06-07T00:00:00Z'));
    expect(result?.releaseNotes, 'X360 Mobile preview fixes');
    expect(
      result?.downloadUrl,
      'https://github.com/Ashnar2602/X360-Mobile---OFFICIAL/releases/'
      'download/v0.5.3_%E9%A2%84%E8%A7%88%E7%89%88/'
      'X360_0.5.3_preview.apk',
    );
    expect(
      result?.devDownloadUrl,
      'https://github.com/Ashnar2602/X360-Mobile---OFFICIAL/releases/'
      'download/v0.5.3_%E9%A2%84%E8%A7%88%E7%89%88/'
      'X360_0.5.3_preview.apk',
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

Emulator _x360Mobile() {
  return const Emulator(
    id: 'x360_mobile',
    name: 'X360 Mobile',
    openSource: false,
    sourceType: 'github',
    sourceUrl: 'https://github.com/Ashnar2602/X360-Mobile---OFFICIAL',
    playStoreId: '',
    website: 'https://www.x360mobile.com/',
    core: '',
    compatibility: 'low',
    minAndroid: '11.0',
    description: 'test',
    downloadUrl:
        'https://github.com/Ashnar2602/X360-Mobile---OFFICIAL/releases/latest/download/X360_0.5.2_public.apk',
    devUrl: 'https://github.com/Ashnar2602/X360-Mobile---OFFICIAL/releases',
  );
}
