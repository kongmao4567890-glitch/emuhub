#!/usr/bin/env python3
"""
fetch_all_versions.py
=====================
读取 emulators.json 中所有 GitHub 来源的模拟器，
通过 GitHub API 获取每个模拟器的：
  - 版本号 (version / tag)
  - 发布日期 (release date)
  - 更新说明 (release notes / changelog)
  - commit SHA
  - APK 下载链接

按仓库去重（同一仓库只请求一次），结果写入 assets/version_cache/ 目录。

用法:
    python3 fetch_all_versions.py                    # 抓取并打印摘要
    python3 fetch_all_versions.py --save             # 抓取并保存到 version_cache
    python3 fetch_all_versions.py --save --token XX  # 带 GitHub token（提高 API 配额）
    python3 fetch_all_versions.py --json             # 输出 JSON
"""

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from urllib.parse import urlparse
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

EMULATORS_JSON = "assets/emulators.json"
VERSION_CACHE_DIR = "assets/version_cache"


def make_headers(token=None):
    """构建 API 请求头。"""
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "emuhub-version-fetcher",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def fetch_json(url, token=None, timeout=15):
    """获取 JSON API，返回解析后的 dict/list。"""
    req = Request(url, headers=make_headers(token))
    with urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def parse_repo_url(url):
    """从 GitHub URL 解析出 (owner, repo)。"""
    if not url:
        return None
    try:
        parts = urlparse(url)
        if "github.com" not in parts.netloc:
            return None
        segments = [s for s in parts.path.split("/") if s]
        if len(segments) < 2:
            return None
        owner = segments[0]
        repo = segments[1].replace(".git", "")
        return (owner, repo)
    except Exception:
        return None


def format_date(iso_str):
    """ISO 8601 -> YYYY-MM-DD。"""
    if not iso_str:
        return ""
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        return dt.strftime("%Y-%m-%d")
    except Exception:
        return iso_str[:10] if len(iso_str) >= 10 else iso_str


def strip_v_prefix(tag):
    """去除版本号前的 v/V 前缀。"""
    v = tag.strip()
    if v.startswith("v") or v.startswith("V"):
        v = v[1:]
    return v


def is_version_like(s):
    """判断字符串是否像版本号（包含数字和点）。"""
    return bool(re.search(r"\d+\.\d+", s))


def extract_version(tag, name):
    """从 tag_name 或 name 中提取版本号。

    某些仓库的 tag 是 "latest" 或非版本号，此时尝试从 name 中提取。
    """
    # 优先用 tag
    if tag and is_version_like(tag):
        return strip_v_prefix(tag)

    # tag 不是版本号，尝试从 name 中提取
    for source in [name, tag]:
        if not source:
            continue
        # 匹配 v1.2.3 或 1.2.3
        match = re.search(r"v?(\d+\.\d+(?:\.\d+)*)", source)
        if match:
            return match.group(1)

    # 都不行，返回原始 tag（去掉 v 前缀）
    return strip_v_prefix(tag) if tag else ""


def extract_apk_url(release):
    """从 release assets 中提取 APK 下载链接。"""
    assets = release.get("assets", [])
    if not isinstance(assets, list):
        return ""
    arm64_apk = None
    any_apk = None
    for asset in assets:
        name = asset.get("name", "").lower()
        url = asset.get("browser_download_url", "")
        if not url or not name.endswith(".apk"):
            continue
        if any(k in name for k in ("arm64", "aarch64", "arm64-v8a")):
            arm64_apk = url
        any_apk = any_apk or url
    return arm64_apk or any_apk or ""


def fetch_commit_info(owner, repo, tag, token=None):
    """获取 tag 对应 commit 的 SHA 和日期。"""
    api_base = f"https://api.github.com/repos/{owner}/{repo}"
    try:
        ref = fetch_json(f"{api_base}/git/refs/tags/{tag}", token)
        sha = ref.get("object", {}).get("sha", "")
        if sha:
            commit = fetch_json(f"{api_base}/commits/{sha}", token)
            return {
                "sha": sha,
                "date": commit.get("commit", {})
                .get("committer", {})
                .get("date", ""),
            }
    except (HTTPError, URLError):
        pass
    return None


def fetch_release_for_repo(owner, repo, token=None):
    """获取单个 GitHub 仓库的最新版本信息（版本号+更新说明+commit+APK）。

    策略（按优先级）：
    1. releases/latest API — 有 "latest" 标记的仓库
    2. releases?per_page=1 — 有 release 但无 latest 标记
    3. tags?per_page=1 — 完全无 release，用最新 tag
    """
    api_base = f"https://api.github.com/repos/{owner}/{repo}"
    result = {
        "version": "",
        "tag": "",
        "releaseDate": "",
        "releaseNotes": "",
        "author": "",
        "commitSha": "",
        "commitDate": "",
        "htmlUrl": "",
        "downloadUrl": "",
        "hasRelease": False,
        "error": "",
    }

    # 策略 1: releases/latest
    try:
        rel = fetch_json(f"{api_base}/releases/latest", token)
        tag = rel.get("tag_name", "")
        name = rel.get("name", "")
        version = extract_version(tag, name)
        result.update({
            "tag": tag,
            "version": version,
            "releaseDate": format_date(rel.get("published_at", "")),
            "releaseNotes": rel.get("body", "") or "",
            "author": rel.get("author", {}).get("login", ""),
            "htmlUrl": rel.get("html_url", ""),
            "downloadUrl": extract_apk_url(rel),
            "hasRelease": True,
        })
        # 获取 commit 信息
        if tag:
            commit_info = fetch_commit_info(owner, repo, tag, token)
            if commit_info:
                result["commitSha"] = commit_info["sha"][:7]
                result["commitDate"] = format_date(commit_info["date"])
        return result
    except HTTPError as e:
        if e.code == 404:
            pass  # 无 latest release，继续策略 2
        elif e.code == 403:
            result["error"] = "rate_limited"
            return result
        else:
            result["error"] = f"http_{e.code}"
    except URLError as e:
        result["error"] = str(e)
        return result

    # 策略 2: releases 列表
    try:
        releases = fetch_json(f"{api_base}/releases?per_page=1", token)
        if releases and isinstance(releases, list) and len(releases) > 0:
            rel = releases[0]
            tag = rel.get("tag_name", "")
            name = rel.get("name", "")
            version = extract_version(tag, name)
            result.update({
                "tag": tag,
                "version": version,
                "releaseDate": format_date(rel.get("published_at", "")),
                "releaseNotes": rel.get("body", "") or "",
                "author": rel.get("author", {}).get("login", ""),
                "htmlUrl": rel.get("html_url", ""),
                "downloadUrl": extract_apk_url(rel),
                "hasRelease": True,
            })
            if tag:
                commit_info = fetch_commit_info(owner, repo, tag, token)
                if commit_info:
                    result["commitSha"] = commit_info["sha"][:7]
                    result["commitDate"] = format_date(commit_info["date"])
            return result
    except (HTTPError, URLError):
        pass

    # 策略 3: tags 列表
    try:
        tags = fetch_json(f"{api_base}/tags?per_page=1", token)
        if tags and isinstance(tags, list) and len(tags) > 0:
            tag = tags[0].get("name", "")
            result.update({
                "tag": tag,
                "version": strip_v_prefix(tag),
                "releaseNotes": "",
                "hasRelease": False,
            })
            commit_sha = tags[0].get("commit", {}).get("sha", "")
            if commit_sha:
                result["commitSha"] = commit_sha[:7]
                try:
                    commit = fetch_json(f"{api_base}/commits/{commit_sha}", token)
                    result["commitDate"] = format_date(
                        commit.get("commit", {})
                        .get("committer", {})
                        .get("date", "")
                    )
                except (HTTPError, URLError):
                    pass
            return result
    except (HTTPError, URLError):
        pass

    return result


def load_emulators(json_path):
    """从 emulators.json 加载所有 GitHub 来源的模拟器。"""
    with open(json_path, encoding="utf-8") as f:
        data = json.load(f)

    emulators = []
    for console in data.get("consoles", []):
        for emu in console.get("emulators", []):
            if emu.get("sourceType") == "github" and emu.get("sourceUrl"):
                parsed = parse_repo_url(emu["sourceUrl"])
                if parsed:
                    emulators.append({
                        "id": emu["id"],
                        "name": emu["name"],
                        "core": emu.get("core", ""),
                        "owner": parsed[0],
                        "repo": parsed[1],
                        "sourceUrl": emu["sourceUrl"],
                    })
    return emulators


def fetch_all(emulators, token=None, delay=0.3):
    """抓取所有模拟器的版本信息（按仓库去重）。"""
    repo_cache = {}
    repo_keys = []
    for emu in emulators:
        key = f"{emu['owner']}/{emu['repo']}"
        if key not in repo_cache:
            repo_cache[key] = None
            repo_keys.append(key)

    print(f"📊 共 {len(emulators)} 个模拟器，{len(repo_keys)} 个唯一仓库", file=sys.stderr)

    results = {}
    fetched = 0
    failed = 0

    for i, key in enumerate(repo_keys, 1):
        owner, repo = key.split("/", 1)
        print(f"[{i}/{len(repo_keys)}] {key} ... ", end="", file=sys.stderr, flush=True)

        try:
            info = fetch_release_for_repo(owner, repo, token)
            repo_cache[key] = info
            if info.get("error"):
                failed += 1
                print(f"⚠️ {info['error']}", file=sys.stderr)
            else:
                fetched += 1
                ver = info.get("version", "?")
                has_notes = "📝" if info.get("releaseNotes") else "  "
                print(f"✅ v{ver} {has_notes}", file=sys.stderr)
        except Exception as e:
            failed += 1
            repo_cache[key] = {"version": "", "error": str(e)}
            print(f"❌ {e}", file=sys.stderr)

        if delay and i < len(repo_keys):
            time.sleep(delay)

    # 将仓库信息映射到每个模拟器
    for emu in emulators:
        key = f"{emu['owner']}/{emu['repo']}"
        info = repo_cache.get(key, {})
        results[emu["id"]] = {
            "emulatorId": emu["id"],
            "name": emu["name"],
            "core": emu["core"],
            "repo": key,
            "version": info.get("version", ""),
            "tag": info.get("tag", ""),
            "releaseDate": info.get("releaseDate", ""),
            "releaseNotes": info.get("releaseNotes", ""),
            "author": info.get("author", ""),
            "commitSha": info.get("commitSha", ""),
            "commitDate": info.get("commitDate", ""),
            "htmlUrl": info.get("htmlUrl", "") or f"https://github.com/{key}/releases",
            "downloadUrl": info.get("downloadUrl", ""),
            "hasRelease": info.get("hasRelease", False),
            "fetchedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }

    return results, fetched, failed


def save_version_cache(results, cache_dir):
    """保存每个模拟器的版本缓存到单独的 JSON 文件。"""
    os.makedirs(cache_dir, exist_ok=True)
    saved = 0
    for emu_id, info in results.items():
        path = os.path.join(cache_dir, f"{emu_id}.json")
        cache = {
            "emulatorId": info["emulatorId"],
            "version": info["version"],
            "releaseDate": info["releaseDate"],
            "releaseNotes": info["releaseNotes"],
            "author": info["author"],
            "commitSha": info["commitSha"],
            "commitDate": info["commitDate"],
            "htmlUrl": info["htmlUrl"],
            "downloadUrl": info["downloadUrl"],
            "source": "github-api",
            "fetchedAt": info["fetchedAt"],
        }
        with open(path, "w", encoding="utf-8") as f:
            json.dump(cache, f, ensure_ascii=False, indent=2)
        saved += 1
    return saved


def print_summary(results, fetched, failed):
    """打印摘要表格。"""
    print("=" * 90)
    print(f"  📋 全部模拟器版本信息（版本号 + 更新说明）")
    print(f"  仓库成功: {fetched} | 失败: {failed} | 模拟器总数: {len(results)}")
    print("=" * 90)
    print()

    with_version = [(k, v) for k, v in results.items() if v["version"]]
    without_version = [(k, v) for k, v in results.items() if not v["version"]]

    print(f"{'模拟器名称':<35s} {'版本':<14s} {'发布日期':<12s} {'更新说明':<6s} {'仓库'}")
    print("-" * 90)
    for emu_id, info in sorted(with_version, key=lambda x: x[1]["name"]):
        has_notes = "✅ 有" if info["releaseNotes"] else "❌ 无"
        print(f"{info['name']:<35s} v{info['version']:<12s} {info['releaseDate']:<12s} {has_notes:<6s} {info['repo']}")

    if without_version:
        print(f"\n⚠️ 未获取到版本的模拟器 ({len(without_version)}):")
        for emu_id, info in sorted(without_version, key=lambda x: x[1]["name"]):
            print(f"  {info['name']:<35s} ({info['repo']})")

    # 统计有更新说明的比例
    with_notes = sum(1 for v in results.values() if v["releaseNotes"])
    print(f"\n📈 统计: {with_notes}/{len(with_version)} 个有版本的模拟器包含更新说明")

    print(f"\n⏰ 获取时间: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}")
    print("=" * 90)


def main():
    parser = argparse.ArgumentParser(description="抓取所有模拟器的版本信息+更新说明")
    parser.add_argument("--save", action="store_true", help="保存到 version_cache 目录")
    parser.add_argument("--token", default=None, help="GitHub token（提高 API 配额）")
    parser.add_argument("--json", action="store_true", help="输出 JSON")
    parser.add_argument("--delay", type=float, default=0.3, help="请求间隔秒数")
    parser.add_argument("--emulators-json", default=EMULATORS_JSON, help="emulators.json 路径")
    args = parser.parse_args()

    token = args.token or os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")

    emulators = load_emulators(args.emulators_json)
    print(f"📦 加载了 {len(emulators)} 个 GitHub 来源模拟器", file=sys.stderr)

    results, fetched, failed = fetch_all(emulators, token, args.delay)

    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
    elif args.save:
        print_summary(results, fetched, failed)
        saved = save_version_cache(results, VERSION_CACHE_DIR)
        print(f"\n✅ 已保存 {saved} 个版本缓存到 {VERSION_CACHE_DIR}/")
    else:
        print_summary(results, fetched, failed)


if __name__ == "__main__":
    main()
