/// 版本号对比工具。
///
/// 负责将各来源抓取到的“脏”版本号规范化，并提供新旧版本比较能力。
/// 规范化后的版本号为纯数字点分形式，比较时按数值段逐段对比，
/// 支持任意段数（如 `2.6.5.2` 这样的四段版本号），
/// 段数不同时短的一侧按 `0` 补齐（`1.2` 与 `1.2.0` 视为相等）。
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
  /// 两者经 [normalize] 规范化后按数值段逐段比较（短的一侧补 0），
  /// 因此 `2.6.5.2 > 2.6.5.1`、`2024.03 == 2024.3`（前导零按数值处理）。
  /// 若存在空段等非法格式，则退化为字符串比较。
  ///
  /// 若 [latest] 为空，返回 `false`；若 [current] 为空，返回 `true`。
  static bool isNewer(String current, String latest) {
    final normalizedCurrent = normalize(current);
    final normalizedLatest = normalize(latest);

    if (normalizedLatest.isEmpty) return false;
    if (normalizedCurrent.isEmpty) return true;
    if (normalizedLatest == normalizedCurrent) return false;

    final currentParts = _numericParts(normalizedCurrent);
    final latestParts = _numericParts(normalizedLatest);

    if (currentParts != null && latestParts != null) {
      final maxLength = currentParts.length > latestParts.length
          ? currentParts.length
          : latestParts.length;
      for (var i = 0; i < maxLength; i++) {
        final c = i < currentParts.length ? currentParts[i] : 0;
        final l = i < latestParts.length ? latestParts[i] : 0;
        if (l != c) return l > c;
      }
      return false;
    }

    // 非法格式（含空段），退化为字符串比较
    return normalizedLatest.compareTo(normalizedCurrent) > 0;
  }

  /// 将规范化后的版本号拆分为数值段。
  ///
  /// 任一一段为空（如 `1..2`、`.1`、`1.`）时返回 null，表示格式非法。
  static List<int>? _numericParts(String version) {
    final segments = version.split('.');
    final result = <int>[];
    for (final segment in segments) {
      if (segment.isEmpty) return null;
      final value = int.tryParse(segment);
      if (value == null) return null;
      result.add(value);
    }
    return result;
  }
}
