import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:emuhub/data/repositories/settings_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('application auto update defaults to enabled and persists', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = SettingsRepository(preferences);

    expect(repository.getSettings().appAutoUpdateEnabled, isTrue);
    await repository.saveSettings(
      repository.getSettings().copyWith(appAutoUpdateEnabled: false),
    );
    expect(repository.getSettings().appAutoUpdateEnabled, isFalse);
  });
}
