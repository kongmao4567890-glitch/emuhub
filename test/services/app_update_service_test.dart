import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:emuhub/services/app_update/app_update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('reads the latest release from the quota-free update manifest',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: _manifest(211),
            ),
          );
        },
      ),
    );
    final service = AppUpdateService(
      preferences: preferences,
      dio: dio,
      currentBuildLoader: () async => 209,
    );

    final result = await service.checkForUpdate();

    expect(result.installedBuildNumber, 209);
    expect(result.release?.buildNumber, 211);
    expect(result.release?.apkSize, 1024);
    expect(result.release?.checksumUrl, endsWith('.sha256'));
  });

  test('does not report an update when installed build is current', () async {
    final preferences = await SharedPreferences.getInstance();
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: _manifest(211),
          ),
        ),
      ),
    );
    final service = AppUpdateService(
      preferences: preferences,
      dio: dio,
      currentBuildLoader: () async => 211,
    );

    expect((await service.checkForUpdate()).hasUpdate, isFalse);
  });

  test('turns GitHub 403 into a concise user-facing error', () async {
    final preferences = await SharedPreferences.getInstance();
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.reject(
          DioException(
            requestOptions: options,
            response: Response<dynamic>(
              requestOptions: options,
              statusCode: 403,
            ),
            type: DioExceptionType.badResponse,
          ),
        ),
      ),
    );
    final service = AppUpdateService(
      preferences: preferences,
      dio: dio,
      currentBuildLoader: () async => 1,
    );

    expect(
      service.checkForUpdate(),
      throwsA(
        isA<AppUpdateException>().having(
          (error) => error.toString(),
          'message',
          'GitHub 暂时拒绝访问，请稍后重试',
        ),
      ),
    );
  });

  test('throttles automatic checks and repeated prompts', () async {
    final preferences = await SharedPreferences.getInstance();
    final service = AppUpdateService(
      preferences: preferences,
      currentBuildLoader: () async => 1,
    );
    final now = DateTime(2026, 8, 20, 12);

    expect(service.isAutomaticCheckDue(now: now), isTrue);
    await service.markAutomaticCheckStarted(now: now);
    expect(
      service.isAutomaticCheckDue(now: now.add(const Duration(hours: 5))),
      isFalse,
    );
    expect(
      service.isAutomaticCheckDue(now: now.add(const Duration(hours: 6))),
      isTrue,
    );

    expect(service.shouldPromptAutomatically(211, now: now), isTrue);
    await service.markPrompted(211, now: now);
    expect(
      service.shouldPromptAutomatically(
        211,
        now: now.add(const Duration(hours: 11)),
      ),
      isFalse,
    );
    expect(
      service.shouldPromptAutomatically(212, now: now),
      isTrue,
    );
  });
}

Map<String, dynamic> _manifest(int build) {
  return {
    'schemaVersion': 1,
    'buildNumber': build,
    'tagName': 'v1.0.$build',
    'name': 'EmuHub v1.0.$build',
    'notes': 'Release notes',
    'publishedAt': '2026-08-20T01:00:00Z',
    'apkSize': 1024,
    'apkUrl': 'https://example.com/v1.0.$build/app-release.apk',
    'checksumUrl':
        'https://example.com/v1.0.$build/app-release.apk.sha256',
  };
}
