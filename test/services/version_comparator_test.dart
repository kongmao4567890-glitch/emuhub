import 'package:flutter_test/flutter_test.dart';

import 'package:emuhub/services/update/version_comparator.dart';

void main() {
  group('VersionComparator.normalize', () {
    test('extracts versions from common release tag formats', () {
      expect(VersionComparator.normalize('v1.2.3'), '1.2.3');
      expect(VersionComparator.normalize('release-2024.01'), '2024.01');
      expect(VersionComparator.normalize('android-1.2.3-rc.1'), '1.2.3');
      expect(VersionComparator.normalize('V2.0+build.9'), '2.0');
    });
  });

  group('VersionComparator.isNewer', () {
    test('compares numeric segments without lexicographic mistakes', () {
      expect(VersionComparator.isNewer('1.9.9', '1.10.0'), isTrue);
      expect(VersionComparator.isNewer('2.6.5.1', '2.6.5.2'), isTrue);
      expect(VersionComparator.isNewer('2024.03', '2024.3'), isFalse);
      expect(VersionComparator.isNewer('1.2', '1.2.0'), isFalse);
    });

    test('orders prerelease and stable versions', () {
      expect(VersionComparator.isNewer('1.0.0-rc1', '1.0.0'), isTrue);
      expect(VersionComparator.isNewer('1.0.0', '1.0.0-rc2'), isFalse);
      expect(
        VersionComparator.isNewer('1.0.0-beta.9', '1.0.0-rc.1'),
        isTrue,
      );
      expect(VersionComparator.isNewer('1.0.0-rc1', '1.0.0-rc2'), isTrue);
    });

    test('ignores build metadata', () {
      expect(
        VersionComparator.isNewer('1.0.0+build.1', '1.0.0+build.2'),
        isFalse,
      );
    });
  });
}
