import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:emuhub/data/models/emulator.dart';
import 'package:emuhub/services/update/forgejo_adapter.dart';

void main() {
  test('selects the newer Eden nightly from its separate repository', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final path = options.uri.path;
          if (path.contains('/api/v1/repos/eden-emu/eden/releases')) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: [
                  {
                    'tag_name': 'v0.2.1',
                    'name': 'Eden v0.2.1',
                    'prerelease': false,
                    'published_at': '2026-06-01T19:57:41+02:00',
                    'body': 'Stable notes',
                    'assets': <dynamic>[],
                  },
                ],
              ),
            );
            return;
          }
          if (path.contains('/api/v1/repos/eden-ci/nightly/releases')) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: [
                  {
                    'tag_name': 'v1785957437.a0f1cd1baf',
                    'name': 'Eden Nightly - Aug 05 2026',
                    'prerelease': false,
                    'published_at': '2026-08-05T22:07:39+02:00',
                    'body': 'Latest nightly fixes',
                    'assets': <dynamic>[],
                  },
                ],
              ),
            );
            return;
          }
          handler.reject(
            DioException(
              requestOptions: options,
              message: 'Unexpected request: ${options.uri}',
            ),
          );
        },
      ),
    );

    final result = await ForgejoReleasesAdapter(dio: dio).fetchLatestVersion(
      const Emulator(
        id: 'eden',
        name: 'Eden',
        openSource: true,
        sourceType: 'forgejo',
        sourceUrl: 'https://git.eden-emu.dev/eden-emu/eden',
        playStoreId: '',
        website: 'https://git.eden-emu.dev/eden-emu/eden',
        core: '',
        compatibility: 'medium',
        minAndroid: '9.0',
        description: 'test',
        downloadUrl: 'https://git.eden-emu.dev/eden-emu/eden/releases',
        devUrl: 'https://git.eden-emu.dev/eden-emu/eden/releases',
        nightlyUrl: 'https://git.eden-emu.dev/eden-ci/nightly/releases',
      ),
    );

    expect(result?.version, '1785957437.a0f1cd1baf');
    expect(
      result?.releaseDate,
      DateTime.parse('2026-08-05T22:07:39+02:00'),
    );
    expect(result?.releaseNotes, 'Latest nightly fixes');
    expect(
      result?.downloadUrl,
      'https://git.eden-emu.dev/eden-ci/nightly/releases',
    );
  });

  test('selects a newer release from a separate Canary repository', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final path = options.uri.path;
          if (path.contains('/api/v1/repos/projects/Ryubing/releases')) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: [
                  {
                    'tag_name': '1.3.3',
                    'name': '1.3.3',
                    'prerelease': false,
                    'published_at': '2025-10-11T07:11:39Z',
                    'body': 'Stable release notes',
                    'assets': <dynamic>[],
                  },
                ],
              ),
            );
            return;
          }
          if (path.contains('/api/v1/repos/Ryubing/Canary/releases')) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: [
                  {
                    'tag_name': '1.3.340',
                    'name': 'Canary 1.3.340',
                    'prerelease': false,
                    'published_at': '2026-07-30T21:22:35Z',
                    'body': 'Latest Canary fixes',
                    'assets': <dynamic>[],
                  },
                ],
              ),
            );
            return;
          }
          handler.reject(
            DioException(
              requestOptions: options,
              message: 'Unexpected request: ${options.uri}',
            ),
          );
        },
      ),
    );

    final result = await ForgejoReleasesAdapter(dio: dio).fetchLatestVersion(
      const Emulator(
        id: 'ryubing_pc',
        name: 'Ryubing',
        openSource: true,
        sourceType: 'forgejo',
        sourceUrl: 'https://git.ryujinx.app/projects/Ryubing',
        playStoreId: '',
        website: 'https://git.ryujinx.app/projects/Ryubing',
        core: '',
        compatibility: 'high',
        minAndroid: '',
        description: 'test',
        downloadUrl: 'https://git.ryujinx.app/projects/Ryubing/releases',
        nightlyUrl: 'https://git.ryujinx.app/Ryubing/Canary/releases',
        platforms: ['windows', 'linux', 'macos'],
        desktopRequirements: '64 位 PC',
      ),
    );

    expect(result?.version, '1.3.340');
    expect(result?.releaseNotes, 'Latest Canary fixes');
    expect(
      result?.downloadUrl,
      'https://git.ryujinx.app/Ryubing/Canary/releases',
    );
    expect(result?.devDownloadUrl, isNull);
  });
}
