import 'package:pub_semver/pub_semver.dart';

/// 版本号对比工具。
///
/// 负责将各来源抓取到的“脏”版本号规范化，并提供新旧版本比较能力。
/// 优先使用 [pub_semver](https://pub.dev/packages/pub_semver) 进行语义化比较，
/// 解析失败时退化为字符串比较，保证健壮性。
class VersionComparator {
  VersionComparator._();

  /// 规范化版本号字符串。
  ///
  /// 处理步骤：
  /// 1. 去除首尾空白；
  /// 2. 去除 `v` / `V` 前缀（如 `v1.2.3` -> `1.2.3`）；
  /// 3. 去除 `-beta` / `-rc.1` 等预发布后缀；
  /// 4. 去除 `+build` 元数据后缀；
  /// 5. 仅保留数字与点号，过滤掉其它字符。
  ///
  /// 例如：`V1.2.3-beta.1+build5` -> `1.2.3`。
  static String normalize(String version) {
    var v = version.trim();

    // 去掉 v / V 前缀
    if (v.startsWith('v') || v.startsWith('V')) {
      v = v.substring(1);
    }

    // 去掉预发布后缀（-beta / -rc 等）
    final dashIndex = v.indexOf('-');
    if (dashIndex > 0) {
      v = v.substring(0, dashIndex);
    }

    // 去掉构建元数据后缀（+build 等）
    final plusIndex = v.indexOf('+');
    if (plusIndex > 0) {
      v = v.substring(0, plusIndex);
    }

    // 仅保留数字和点
    final numericPart = v.replaceAll(RegExp(r'[^0-9.]'), '');
    return numericPart.trim();
  }

  /// 判断 [latest] 是否比 [current] 更新。
  ///
  /// 优先使用 `pub_semver` 的语义化版本比较；若任一版本无法解析为合法
  /// semver，则退化为字符串比较（仅当两者不同且 latest 字典序更大时返回 true）。
  ///
  /// 若 [latest] 为空，返回 `false`；若 [current] 为空，返回 `true`。
  static bool isNewer(String current, String latest) {
    final normalizedCurrent = normalize(current);
    final normalizedLatest = normalize(latest);

    if (normalizedLatest.isEmpty) return false;
    if (normalizedCurrent.isEmpty) return true;
    if (normalizedLatest == normalizedCurrent) return false;

    try {
      final currentVersion = Version.parse(_ensureSemver(normalizedCurrent));
      final latestVersion = Version.parse(_ensureSemver(normalizedLatest));
      return latestVersion > currentVersion;
    } catch (_) {
      // pub_semver 解析失败，退化为字符串比较
      return normalizedLatest.compareTo(normalizedCurrent) > 0;
    }
  }

  /// 将版本号补齐为至少三段（major.minor.patch），不足补 `0`。
  ///
  /// pub_semver 要求版本号至少包含 `major.minor.patch`，而部分来源只
  /// 提供 `1.2` 这样的两段版本号，需要补齐后才能解析。
  static String _ensureSemver(String version) {
    final parts = version.split('.').where((p) => p.isNotEmpty).toList();
    while (parts.length < 3) {
      parts.add('0');
    }
    return parts.take(3).join('.');
  }
}
