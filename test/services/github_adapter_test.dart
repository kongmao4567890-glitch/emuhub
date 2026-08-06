import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:emuhub/data/models/emulator.dart';
import 'package:emuhub/services/update/github_adapter.dart';

void main() {
  test('uses the latest timestamp instead of the Releases page order',
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
                    'https://github.com/ARMSX2/ARMSX2/releases/tag/2.6.6.4',
                  ],
                }),
              ),
            );
            return;
          }
          if (path.endsWith('/releases.atom')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '''<?xml version="1.0" encoding="UTF-8"?>
<feed>
  <entry>
    <updated>2026-08-05T05:49:29Z</updated>
    <link rel="alternate" href="https://github.com/ARMSX2/ARMSX2/releases/tag/2.6.6.4"/>
    <content type="html">&lt;p&gt;Stable 2.6.6.4 fixes&lt;/p&gt;</content>
  </entry>
  <entry>
    <updated>2026-08-05T11:17:25Z</updated>
    <link rel="alternate" href="https://github.com/ARMSX2/ARMSX2/releases/tag/nightly-20260805"/>
    <content type="html">&lt;p&gt;Nightly fixes&lt;/p&gt;</content>
  </entry>
</feed>''',
              ),
            );
            return;
          }
          if (path.endsWith('/releases')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '<a href="/ARMSX2/ARMSX2/releases/tag/nightly-20260805">'
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
                      '2.6.6.4',
                ),
                statusCode: 200,
                data: '<relative-time datetime="2026-08-05T05:49:29Z"></relative-time>'
                    '<div class="markdown-body">Stable 2.6.6.4 fixes</div>',
              ),
            );
            return;
          }
          if (path.contains('/expanded_assets/2.6.6.4')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '<a href="/ARMSX2/ARMSX2/releases/download/2.6.6.4/'
                    'ARMSX2-2.6.6.4.apk">APK</a>',
              ),
            );
            return;
          }
          if (path.contains('/expanded_assets/nightly-20260805')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '<a href="/ARMSX2/ARMSX2/releases/download/nightly-20260805/'
                    'ARMSX2-nightly-20260805.apk">APK</a>',
              ),
            );
            return;
          }
          if (path.endsWith('/releases/tag/nightly-20260805')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '<relative-time datetime="2026-08-05T11:17:25Z"></relative-time>'
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

    expect(result?.version, 'nightly-20260805');
    expect(result?.releaseDate, DateTime.parse('2026-08-05T11:17:25Z'));
    expect(result?.releaseNotes, 'Nightly fixes');
    expect(result?.devReleaseNotes, 'Nightly fixes');
    expect(
      result?.devDownloadUrl,
      'https://github.com/ARMSX2/ARMSX2/releases/download/nightly-20260805/'
      'ARMSX2-nightly-20260805.apk',
    );
    expect(
      result?.downloadUrl,
      'https://github.com/ARMSX2/ARMSX2/releases/download/nightly-20260805/'
      'ARMSX2-nightly-20260805.apk',
    );
  });

  test('derives a build version from a mutable nightly tag title', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final path = options.uri.path;
          if (path.endsWith('/releases.atom')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '''<?xml version="1.0" encoding="UTF-8"?>
<feed>
  <entry>
    <updated>2026-07-16T07:17:29Z</updated>
    <link rel="alternate" href="https://github.com/nexium-emu/nexium-nightly/releases/tag/nightly"/>
    <title>NeXium nightly 2026.07.16 (f65720a)</title>
    <content type="html">&lt;p&gt;Automated CI build&lt;/p&gt;</content>
  </entry>
</feed>''',
              ),
            );
            return;
          }
          if (path.contains('/expanded_assets/nightly')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '<a href="/nexium-emu/nexium-nightly/releases/'
                    'download/nightly/nexium-windows-x86_64.zip">ZIP</a>',
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
      _nexium(),
    );

    expect(result?.version, 'nightly-2026.07.16');
    expect(result?.releaseDate, DateTime.parse('2026-07-16T07:17:29Z'));
    expect(result?.releaseNotes, 'Automated CI build');
  });

  test('compares release times across a separate GitHub CI repository',
      () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final path = options.uri.path;
          if (path == '/citron-neo/emulator/releases.atom') {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '''<feed>
  <entry>
    <updated>2026-07-01T00:00:00Z</updated>
    <link rel="alternate" href="https://github.com/citron-neo/emulator/releases/tag/v0.10.0"/>
    <title>Citron 0.10.0</title>
  </entry>
</feed>''',
              ),
            );
            return;
          }
          if (path == '/citron-neo/CI/releases.atom') {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '''<feed>
  <entry>
    <updated>2026-08-05T18:00:00Z</updated>
    <link rel="alternate" href="https://github.com/citron-neo/CI/releases/tag/nightly-20260805"/>
    <title>Citron nightly 20260805</title>
  </entry>
</feed>''',
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
      _citron(),
    );

    expect(result?.version, 'nightly-20260805');
    expect(result?.releaseDate, DateTime.parse('2026-08-05T18:00:00Z'));
    expect(
      result?.downloadUrl,
      'https://github.com/citron-neo/CI/releases/tag/nightly-20260805',
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
          if (path.endsWith('/releases.atom')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '''<?xml version="1.0" encoding="UTF-8"?>
<feed>
  <entry>
    <updated>2026-06-07T00:00:00Z</updated>
    <link rel="alternate" href="https://github.com/Ashnar2602/X360-Mobile---OFFICIAL/releases/tag/v0.5.3_%E9%A2%84%E8%A7%88%E7%89%88"/>
    <content type="html">&lt;p&gt;X360 Mobile preview fixes&lt;/p&gt;</content>
  </entry>
  <entry>
    <updated>2026-06-06T00:00:00Z</updated>
    <link rel="alternate" href="https://github.com/Ashnar2602/X360-Mobile---OFFICIAL/releases/tag/v0.5.2"/>
    <content type="html">&lt;p&gt;Stable fixes&lt;/p&gt;</content>
  </entry>
</feed>''',
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

  test('uses the tagged commit message when a prerelease body is empty',
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
                    'https://github.com/Cxbx-Reloaded/Cxbx-Reloaded/releases',
                  ],
                }),
              ),
            );
            return;
          }
          if (path == '/Cxbx-Reloaded/Cxbx-Reloaded/releases/latest') {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '<a href="/Cxbx-Reloaded/Cxbx-Reloaded/releases/tag/'
                    'CI-585c49a">CI-585c49a</a>',
              ),
            );
            return;
          }
          if (path.endsWith('/releases/tag/CI-585c49a')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '<relative-time datetime="2026-04-19T18:56:36Z">'
                    '</relative-time>',
              ),
            );
            return;
          }
          if (path.contains('/expanded_assets/CI-585c49a')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '',
              ),
            );
            return;
          }
          if (path.endsWith('/repos/Cxbx-Reloaded/Cxbx-Reloaded/releases/latest')) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response<dynamic>(
                  requestOptions: options,
                  statusCode: 404,
                ),
                type: DioExceptionType.badResponse,
              ),
            );
            return;
          }
          if (path.endsWith('/repos/Cxbx-Reloaded/Cxbx-Reloaded/releases')) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: [
                  {
                    'tag_name': 'CI-585c49a',
                    'target_commitish':
                        '585c49a50af1255ab155099e06f24505f9c5a800',
                    'published_at': '2026-04-19T18:56:36Z',
                    'body': null,
                    'assets': <dynamic>[],
                  },
                ],
              ),
            );
            return;
          }
          if (path.endsWith(
            '/repos/Cxbx-Reloaded/Cxbx-Reloaded/commits/CI-585c49a',
          )) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'commit': {
                    'message': 'd3d: invalidate texgen texture state',
                  },
                },
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
      _cxbx(),
      includeDetails: true,
    );

    expect(result?.version, 'CI-585c49a');
    expect(result?.releaseDate, DateTime.parse('2026-04-19T18:56:36Z'));
    expect(result?.releaseNotes, 'd3d: invalidate texgen texture state');
  });

  test('uses the Atom feed when release details are unavailable', () async {
    final dio = Dio();
    var prereleasePageRequests = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final path = options.uri.path;
          if (options.uri.host == 'github.com' &&
              path == '/RPCS3/rpcs3/releases') {
            prereleasePageRequests++;
          }
          if (options.method == 'HEAD' && path.endsWith('/releases/latest')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 302,
                headers: Headers.fromMap({
                  'location': [
                    'https://github.com/RPCS3/rpcs3/releases/tag/v0.0.42',
                  ],
                }),
              ),
            );
            return;
          }
          if (path.endsWith('/releases.atom')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '''<?xml version="1.0" encoding="UTF-8"?>
<feed>
  <entry>
    <updated>2026-07-31T18:15:12Z</updated>
    <link rel="alternate" href="https://github.com/RPCS3/rpcs3/releases/tag/v0.0.42"/>
    <title>v0.0.42 Alpha</title>
    <content type="html">&lt;p&gt;RPCS3 rolling release fixes&lt;/p&gt;&lt;ul&gt;&lt;li&gt;Vulkan fix&lt;/li&gt;&lt;/ul&gt;</content>
  </entry>
</feed>''',
              ),
            );
            return;
          }
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response<dynamic>(
                requestOptions: options,
                statusCode: 403,
              ),
              type: DioExceptionType.badResponse,
            ),
          );
        },
      ),
    );

    final result = await GitHubReleasesAdapter(dio: dio).fetchLatestVersion(
      _rpcs3(),
      includeDetails: true,
    );

    expect(result?.version, '0.0.42');
    expect(result?.releaseDate, DateTime.parse('2026-07-31T18:15:12Z'));
    expect(
      result?.releaseNotes,
      contains('RPCS3 rolling release fixes'),
    );
    expect(result?.releaseNotes, contains('Vulkan fix'));
    expect(prereleasePageRequests, 0);
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

Emulator _cxbx() {
  return const Emulator(
    id: 'cxbx_r',
    name: 'CXBX-R',
    openSource: true,
    sourceType: 'github',
    sourceUrl: 'https://github.com/Cxbx-Reloaded/Cxbx-Reloaded',
    playStoreId: '',
    website: '',
    core: '',
    compatibility: 'low',
    minAndroid: '10.0',
    description: 'test',
    downloadUrl: 'https://github.com/Cxbx-Reloaded/Cxbx-Reloaded/releases',
  );
}

Emulator _rpcs3() {
  return const Emulator(
    id: 'rpcs3_pc',
    name: 'RPCS3',
    openSource: true,
    sourceType: 'github',
    sourceUrl: 'https://github.com/RPCS3/rpcs3',
    playStoreId: '',
    website: 'https://rpcs3.net/',
    core: '',
    compatibility: 'high',
    minAndroid: '',
    description: 'test',
    downloadUrl: 'https://github.com/RPCS3/rpcs3/releases/latest',
    devUrl: 'https://rpcs3.net/download',
    nightlyUrl: 'https://rpcs3.net/builds',
  );
}

Emulator _nexium() {
  return const Emulator(
    id: 'nexium_pc',
    name: 'NeXium',
    openSource: true,
    sourceType: 'github',
    sourceUrl: 'https://github.com/nexium-emu/nexium-nightly',
    playStoreId: '',
    website: 'https://nexium-emu.org/',
    core: '',
    compatibility: 'low',
    minAndroid: '',
    description: 'test',
    downloadUrl: 'https://github.com/nexium-emu/nexium-nightly/releases',
    devUrl: 'https://github.com/nexium-emu/nexium-nightly/releases',
    nightlyUrl: 'https://github.com/nexium-emu/nexium-nightly/releases',
  );
}

Emulator _citron() {
  return const Emulator(
    id: 'citron_neo',
    name: 'Citron Neo',
    openSource: true,
    sourceType: 'github',
    sourceUrl: 'https://github.com/citron-neo/emulator',
    playStoreId: '',
    website: '',
    core: '',
    compatibility: 'medium',
    minAndroid: '9.0',
    description: 'test',
    downloadUrl: 'https://github.com/citron-neo/emulator/releases',
    nightlyUrl: 'https://github.com/citron-neo/CI/releases',
  );
}
