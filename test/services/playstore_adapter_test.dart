import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:emuhub/data/models/emulator.dart';
import 'package:emuhub/services/update/playstore_adapter.dart';

void main() {
  test('parses version, date and release notes from the Play Store page',
      () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response<String>(
            requestOptions: options,
            statusCode: 200,
            data: '''
              [["版本号", "2.0.19.5"]]
              <div><div class="lXlx5">更新日期</div><div>2026年7月10日</div></div>
              <section>
                <header><h2>新变化</h2></header>
                <div itemprop="description">Added Oboe<br>Fixed CHD &amp; CDDA</div>
              </section>
            ''',
          ),
        ),
      ),
    );

    final result = await PlayStoreAdapter(dio: dio).fetchLatestVersion(
      _epsxe(),
    );

    expect(result?.version, '2.0.19.5');
    expect(result?.releaseDate, DateTime(2026, 7, 10));
    expect(result?.releaseNotes, 'Added Oboe\nFixed CHD & CDDA');
  });
}

Emulator _epsxe() {
  return const Emulator(
    id: 'epsxe',
    name: 'ePSXe',
    openSource: false,
    sourceType: 'playstore',
    sourceUrl: '',
    playStoreId: 'com.epsxe.ePSXe',
    website: 'https://www.epsxe.com/android/',
    core: '',
    compatibility: 'high',
    minAndroid: '5.0',
    description: 'test',
    downloadUrl: 'https://play.google.com/store/apps/details?id=com.epsxe.ePSXe',
  );
}
