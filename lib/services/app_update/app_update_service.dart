import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/app_constants.dart';

typedef CurrentBuildLoader = Future<int> Function();
typedef TemporaryDirectoryLoader = Future<Directory> Function();

enum AppInstallResult {
  launched,
  permissionRequired,
  unsupported,
}

class AppRelease {
  const AppRelease({
    required this.buildNumber,
    required this.tagName,
    required this.name,
    required this.notes,
    required this.apkUrl,
    required this.checksumUrl,
    required this.apkSize,
    required this.publishedAt,
  });

  final int buildNumber;
  final String tagName;
  final String name;
  final String notes;
  final String apkUrl;
  final String checksumUrl;
  final int apkSize;
  final DateTime? publishedAt;
}

class AppUpdateCheckResult {
  const AppUpdateCheckResult({
    required this.installedBuildNumber,
    required this.release,
  });

  final int installedBuildNumber;
  final AppRelease? release;

  bool get hasUpdate => release != null;
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Checks, downloads, verifies and launches installation of EmuHub releases.
///
/// The online build number is both the Android `versionCode` and the last
/// component of the GitHub Release tag (`v1.0.<build>`). Comparing those
/// integers avoids false updates caused by display-version formatting.
class AppUpdateService {
  AppUpdateService({
    required SharedPreferences preferences,
    Dio? dio,
    CurrentBuildLoader? currentBuildLoader,
    TemporaryDirectoryLoader? temporaryDirectoryLoader,
  })  : _preferences = preferences,
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 30),
                headers: const {
                  'Accept': 'application/vnd.github+json',
                  'X-GitHub-Api-Version': '2022-11-28',
                  'User-Agent':
                      'EmuHub/1.0 (+https://github.com/kongmao4567890-glitch/emuhub)',
                },
              ),
            ),
        _currentBuildLoader = currentBuildLoader,
        _temporaryDirectoryLoader = temporaryDirectoryLoader;

  static const MethodChannel _platform =
      MethodChannel('com.emuhub.app/app_update');
  static const String _releaseManifestName = 'app-update.json';
  static const Duration automaticCheckInterval = Duration(hours: 6);
  static const Duration automaticPromptInterval = Duration(hours: 12);
  static const String _lastAutomaticCheckKey =
      'app_update_last_automatic_check';
  static const String _lastPromptBuildKey = 'app_update_last_prompt_build';
  static const String _lastPromptAtKey = 'app_update_last_prompt_at';

  final SharedPreferences _preferences;
  final Dio _dio;
  final CurrentBuildLoader? _currentBuildLoader;
  final TemporaryDirectoryLoader? _temporaryDirectoryLoader;

  bool isAutomaticCheckDue({DateTime? now}) {
    final timestamp = _preferences.getInt(_lastAutomaticCheckKey);
    if (timestamp == null) return true;
    final checkedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return (now ?? DateTime.now()).difference(checkedAt) >=
        automaticCheckInterval;
  }

  Future<void> markAutomaticCheckStarted({DateTime? now}) =>
      _preferences.setInt(
        _lastAutomaticCheckKey,
        (now ?? DateTime.now()).millisecondsSinceEpoch,
      );

  bool shouldPromptAutomatically(int buildNumber, {DateTime? now}) {
    final previousBuild = _preferences.getInt(_lastPromptBuildKey);
    final previousTimestamp = _preferences.getInt(_lastPromptAtKey);
    if (previousBuild != buildNumber || previousTimestamp == null) return true;
    final promptedAt = DateTime.fromMillisecondsSinceEpoch(previousTimestamp);
    return (now ?? DateTime.now()).difference(promptedAt) >=
        automaticPromptInterval;
  }

  Future<void> markPrompted(int buildNumber, {DateTime? now}) async {
    await Future.wait([
      _preferences.setInt(_lastPromptBuildKey, buildNumber),
      _preferences.setInt(
        _lastPromptAtKey,
        (now ?? DateTime.now()).millisecondsSinceEpoch,
      ),
    ]);
  }

  Future<AppUpdateCheckResult> checkForUpdate() async {
    final installedBuild = await currentBuildNumber();
    final manifestUrl =
        '${AppConstants.githubRepo}/releases/latest/download/'
        '$_releaseManifestName';
    AppRelease newest;
    try {
      final response = await _dio.get<dynamic>(
        manifestUrl,
        options: Options(
          responseType: ResponseType.json,
          headers: const {'Accept': 'application/json'},
        ),
      );
      newest = _parseManifest(_asMap(response.data));
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 403) {
        throw const AppUpdateException('GitHub 暂时拒绝访问，请稍后重试');
      }
      throw const AppUpdateException('无法连接应用更新服务器，请检查网络后重试');
    } on FormatException catch (error) {
      throw AppUpdateException(error.message.toString());
    }

    return AppUpdateCheckResult(
      installedBuildNumber: installedBuild,
      release: newest.buildNumber > installedBuild ? newest : null,
    );
  }

  Future<int> currentBuildNumber() async {
    if (_currentBuildLoader != null) return _currentBuildLoader();
    if (!Platform.isAndroid) return 0;
    final result = await _platform.invokeMapMethod<String, dynamic>(
      'getAppVersion',
    );
    final raw = result?['versionCode'];
    if (raw is int) return raw;
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  /// Downloads the APK to the app cache and verifies both size and SHA-256.
  Future<File> downloadAndVerify(
    AppRelease release, {
    void Function(int received, int total)? onProgress,
    void Function()? onVerifying,
  }) async {
    final checksumResponse = await _dio.get<String>(
      release.checksumUrl,
      options: Options(
        responseType: ResponseType.plain,
        headers: const {'Accept': 'text/plain'},
      ),
    );
    final expectedHash = _parseSha256(checksumResponse.data);
    if (expectedHash == null) {
      throw const FormatException('更新包校验文件无效');
    }

    final temp = _temporaryDirectoryLoader != null
        ? await _temporaryDirectoryLoader()
        : await getTemporaryDirectory();
    final updateDirectory = Directory('${temp.path}/updates');
    await updateDirectory.create(recursive: true);
    final apk = File(
      '${updateDirectory.path}/emuhub-${release.buildNumber}.apk',
    );
    final partial = File('${apk.path}.part');

    if (await apk.exists() &&
        await _verifyFile(apk, release.apkSize, expectedHash)) {
      onProgress?.call(release.apkSize, release.apkSize);
      return apk;
    }

    if (await partial.exists()) await partial.delete();
    await _dio.download(
      release.apkUrl,
      partial.path,
      deleteOnError: true,
      onReceiveProgress: onProgress,
      options: Options(
        followRedirects: true,
        receiveTimeout: const Duration(minutes: 10),
        headers: const {'Accept': 'application/vnd.android.package-archive'},
      ),
    );

    onVerifying?.call();
    if (!await _verifyFile(partial, release.apkSize, expectedHash)) {
      if (await partial.exists()) await partial.delete();
      throw const FormatException('更新包大小或 SHA-256 校验失败');
    }
    if (await apk.exists()) await apk.delete();
    return partial.rename(apk.path);
  }

  Future<bool> canRequestPackageInstalls() async {
    if (!Platform.isAndroid) return false;
    return await _platform.invokeMethod<bool>('canInstallPackages') ?? false;
  }

  Future<AppInstallResult> installApk(File apk) async {
    if (!Platform.isAndroid) return AppInstallResult.unsupported;
    final result = await _platform.invokeMethod<String>(
      'installApk',
      {'path': apk.path},
    );
    switch (result) {
      case 'launched':
        return AppInstallResult.launched;
      case 'permission_required':
        return AppInstallResult.permissionRequired;
      default:
        return AppInstallResult.unsupported;
    }
  }

  Future<bool> _verifyFile(
    File file,
    int expectedSize,
    String expectedHash,
  ) async {
    if (!await file.exists()) return false;
    if (expectedSize > 0 && (await file.length()) != expectedSize) return false;
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase() == expectedHash.toLowerCase();
  }

  AppRelease _parseManifest(Map<String, dynamic> release) {
    final tag = release['tagName']?.toString().trim() ?? '';
    final buildMatch = RegExp(r'^v1\.0\.(\d+)$').firstMatch(tag);
    final tagBuild = int.tryParse(buildMatch?.group(1) ?? '');
    final buildNumber = _asInt(release['buildNumber']);
    final apkUrl = release['apkUrl']?.toString() ?? '';
    final checksumUrl = release['checksumUrl']?.toString() ?? '';
    if (tagBuild == null || buildNumber <= 0 || tagBuild != buildNumber) {
      throw const FormatException('应用更新清单的版本号无效');
    }
    if (apkUrl.isEmpty || checksumUrl.isEmpty) {
      throw const FormatException('应用更新清单缺少下载地址');
    }

    return AppRelease(
      buildNumber: buildNumber,
      tagName: tag,
      name: release['name']?.toString().trim().isNotEmpty == true
          ? release['name'].toString().trim()
          : tag,
      notes: release['notes']?.toString().trim() ?? '',
      apkUrl: apkUrl,
      checksumUrl: checksumUrl,
      apkSize: _asInt(release['apkSize']),
      publishedAt: DateTime.tryParse(
        release['publishedAt']?.toString() ?? '',
      ),
    );
  }

  String? _parseSha256(String? value) => RegExp(
        r'\b[0-9a-fA-F]{64}\b',
      ).firstMatch(value ?? '')?.group(0)?.toLowerCase();

  int _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }
}
