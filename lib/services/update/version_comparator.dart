/// 版本号对比工具。
///
/// 负责将各来源抓取到的"脏"版本号规范化，并提供新旧版本比较能力。
/// 规范化后的版本号为纯数字点分形式，比较时按数值段逐段对比，
/// 支持任意段数（如 `2.6.5.2` 这样的四段版本号），
/// 段数不同时短的一侧按 `0` 补齐（`1.2` 与 `1.2.0` 视为相等）。
///
/// **预发布版本比较**（遵循 semver 规则）：
/// - `1.0.0` > `1.0.0-rc1`（正式版 > 同版本号的预发布版）
/// - `1.0.0-rc2` > `1.0.0-rc1`（预发布号更大者更新）
/// - `1.0.0-rc.1` > `1.0.0-beta.1`（rc > beta > alpha）
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
  /// 比较规则（遵循 semver）：
  /// 1. 先比较数值部分（`2.6.5.2 > 2.6.5.1`、`2024.03 == 2024.3`）。
  /// 2. 数值部分相等时，比较预发布后缀：
  ///    - 无后缀（正式版）> 有后缀（预发布版）
  ///    - 两者均为预发布版时，按预发布类型优先级和编号比较
  ///      （`rc > beta > alpha`，同类型编号大者更新）
  /// 3. 若存在空段等非法格式，则退化为字符串比较。
  ///
  /// 若 [latest] 为空，返回 `false`；若 [current] 为空，返回 `true`。
  static bool isNewer(String current, String latest) {
    final normalizedCurrent = normalize(current);
    final normalizedLatest = normalize(latest);

    if (normalizedLatest.isEmpty) return false;
    if (normalizedCurrent.isEmpty) return true;

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

      // 数值部分完全相等 → 比较预发布后缀
      // 注意：即使 normalizedLatest != normalizedCurrent（如 "1.0" vs "1.0.0"），
      // 只要数值部分相等就需要比较预发布后缀。
      return _isPrereleaseNewer(current, latest);
    }

    // 非法格式（含空段），退化为字符串比较
    return normalizedLatest.compareTo(normalizedCurrent) > 0;
  }

  /// 当两个版本号的数值部分相等时，比较预发布后缀。
  ///
  /// 返回 `true` 表示 [latest] 的预发布后缀比 [current] 的更新。
  ///
  /// 规则（semver）：
  /// - 正式版（无后缀）> 预发布版（有后缀）
  /// - 两者均为预发布版：按类型优先级（rc > beta > alpha）和编号比较
  /// - 两者均为正式版：返回 false（完全相等）
  static bool _isPrereleaseNewer(String current, String latest) {
    final currentPre = _extractPrereleaseSuffix(current);
    final latestPre = _extractPrereleaseSuffix(latest);

    // 两者都是正式版 → 相等
    if (currentPre.isEmpty && latestPre.isEmpty) return false;

    // current 是正式版，latest 是预发布版 → latest 更旧
    if (currentPre.isEmpty && latestPre.isNotEmpty) return false;

    // current 是预发布版，latest 是正式版 → latest 更新
    if (currentPre.isNotEmpty && latestPre.isEmpty) return true;

    // 两者都是预发布版 → 按类型优先级和编号比较
    final cmp = _comparePrereleaseSuffixes(currentPre, latestPre);
    return cmp < 0; // latest 的后缀优先级更高 → 返回 true
  }

  /// 从原始版本号中提取预发布后缀（`-` 之后、`+` 之前的部分）。
  ///
  /// 例如：`1.2.3-rc.5+build` → `rc.5`
  static String _extractPrereleaseSuffix(String version) {
    var v = version.trim();
    // 去掉 v / V 前缀
    if (v.startsWith('v') || v.startsWith('V')) {
      v = v.substring(1);
    }
    final dashIndex = v.indexOf('-');
    if (dashIndex < 0) return '';
    v = v.substring(dashIndex + 1);
    // 去掉构建元数据
    final plusIndex = v.indexOf('+');
    if (plusIndex >= 0) {
      v = v.substring(0, plusIndex);
    }
    return v.trim();
  }

  /// 比较两个预发布后缀的优先级。
  ///
  /// 返回值：
  /// - 负数：[a] 优先级低于 [b]（即 [b] 更新）
  /// - 正数：[a] 优先级高于 [b]（即 [a] 更新）
  /// - 0：两者优先级相同
  ///
  /// 优先级规则（semver）：
  /// 1. 按类型排序：`rc` > `beta`/`b` > `alpha`/`a` > 其他
  /// 2. 同类型时按编号比较：`rc5` > `rc3`
  /// 3. 无法比较时退化为字符串比较
  static int _comparePrereleaseSuffixes(String a, String b) {
    final aPriority = _prereleasePriority(a);
    final bPriority = _prereleasePriority(b);

    if (aPriority != bPriority) {
      return aPriority - bPriority;
    }

    // 同优先级 → 比较编号
    final aNum = _extractPrereleaseNumber(a);
    final bNum = _extractPrereleaseNumber(b);

    if (aNum != null && bNum != null) {
      return aNum - bNum;
    }

    // 无法提取编号 → 字符串比较
    return a.compareTo(b);
  }

  /// 获取预发布后缀的优先级（数值越大优先级越高）。
  static int _prereleasePriority(String suffix) {
    final lower = suffix.toLowerCase();
    if (lower.startsWith('rc') || lower.startsWith('release')) return 3;
    if (lower.startsWith('beta') || lower.startsWith('b.')) return 2;
    if (lower.startsWith('alpha') || lower.startsWith('a.')) return 1;
    return 0;
  }

  /// 从预发布后缀中提取编号。
  ///
  /// 例如：`rc5` → 5，`beta.3` → 3，`alpha-1` → 1。
  static int? _extractPrereleaseNumber(String suffix) {
    // 查找后缀中的数字部分
    final match = RegExp(r'(\d+)').firstMatch(suffix);
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
    return null;
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
