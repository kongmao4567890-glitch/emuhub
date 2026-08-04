import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:emuhub/data/models/emulator.dart';
import 'package:emuhub/services/update/gitlab_adapter.dart';

void main() {
  test('supports self-hosted GitLab release channels', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.uri.host, 'git.ryujinx.app');
          expect(options.uri.path, contains('/api/v4/projects/'));
          expect(options.uri.toString(), contains('release-channel-master'));
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: [
                {
                  'tag_name': '1.3.0',
                  'created_at': '2026-08-01T00:00:00Z',
                  'description': 'Ryubing desktop fixes',
                },
              ],
            ),
          );
        },
      ),
    );

    final result = await GitLabReleasesAdapter(dio: dio).fetchLatestVersion(
      const Emulator(
        id: 'ryubing_pc',
        name: 'Ryubing',
        openSource: true,
        sourceType: 'gitlab',
        sourceUrl:
            'https://git.ryujinx.app/ryujinx/release-channel-master',
        playStoreId: '',
        website: '',
        core: '',
        compatibility: 'high',
        minAndroid: '',
        description: 'test',
        platforms: ['windows', 'linux', 'macos'],
        desktopRequirements: '64 位 PC',
      ),
    );

    expect(result?.version, '1.3.0');
    expect(result?.releaseNotes, 'Ryubing desktop fixes');
  });
}
