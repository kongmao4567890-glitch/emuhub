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
          expect(options.uri.host, 'git.example.com');
          expect(options.uri.path, contains('/api/v4/projects/'));
          expect(options.uri.toString(), contains('group%2Femulator'));
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: [
                {
                  'tag_name': '1.3.0',
                  'created_at': '2026-08-01T00:00:00Z',
                  'description': 'Self-hosted GitLab release notes',
                },
              ],
            ),
          );
        },
      ),
    );

    final result = await GitLabReleasesAdapter(dio: dio).fetchLatestVersion(
      const Emulator(
        id: 'self_hosted_gitlab',
        name: 'Self-hosted GitLab emulator',
        openSource: true,
        sourceType: 'gitlab',
        sourceUrl: 'https://git.example.com/group/emulator',
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
    expect(result?.releaseNotes, 'Self-hosted GitLab release notes');
  });
}
