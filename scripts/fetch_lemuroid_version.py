#!/usr/bin/env python3
"""
fetch_lemuroid_version.py
=========================
拉取 Swordfish90/Lemuroid 最新 Release 版本信息并显示。

对应截图2中 GitHub Releases 页面展示的信息：
  - 版本号 (tag)
  - Latest 标记
  - 发布者 (author)
  - 发布日期 (published_at)
  - Tag
  - Commit hash
  - 更新日志 (release notes / changelog)
  - Release Assets (APK 下载链接)

用法:
    python3 fetch_lemuroid_version.py            # 终端打印
    python3 fetch_lemuroid_version.py --json      # 输出 JSON
    python3 fetch_lemuroid_version.py --save      # 保存到 assets/version_cache/lemuroid.json
"""

import json
import sys
import os
from datetime import datetime, timezone
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# ── 配置 ──────────────────────────────────────────────
OWNER = "Swordfish90"
REPO = "Lemuroid"
API_BASE = f"https://api.github.com/repos/{OWNER}/{REPO}"
HEADERS = {
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "emuhub-version-fetcher",
}


def api_get(url):
    """发送 GET 请求并返回解析后的 JSON。"""
    req = Request(url, headers=HEADERS)
    with urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_latest_release():
    """获取最新 release 信息。"""
    return api_get(f"{API_BASE}/releases/latest")


def fetch_tag_commit_sha(tag):
    """获取 tag 对应的 commit SHA。"""
    ref = api_get(f"{API_BASE}/git/refs/tags/{tag}")
    return ref["object"]["sha"]


def fetch_commit_info(sha):
    """获取 commit 详细信息（提交日期）。"""
    return api_get(f"{API_BASE}/commits/{sha}")


def format_date(iso_str):
    """ISO 8601 -> YYYY-MM-DD。"""
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        return dt.strftime("%Y-%m-%d")
    except Exception:
        return iso_str


def extract_version_info():
    """提取完整版本信息（对应截图2的内容）。"""
    # 1. 获取最新 release
    release = fetch_latest_release()

    tag = release.get("tag_name", "")
    name = release.get("name", "")
    published_at = release.get("published_at", "")
    author = release.get("author", {}).get("login", "")
    html_url = release.get("html_url", "")
    body = release.get("body", "无更新说明") or "无更新说明"
    is_prerelease = release.get("prerelease", False)

    # 2. 获取 tag 对应的 commit SHA
    commit_sha_full = fetch_tag_commit_sha(tag)
    commit_sha = commit_sha_full[:7]

    # 3. 获取 commit 提交日期
    commit_info = fetch_commit_info(commit_sha_full)
    commit_date = commit_info.get("commit", {}).get("committer", {}).get("date", "")

    # 4. 提取 APK 下载链接
    assets = release.get("assets", [])
    apk_assets = [a for a in assets if a.get("name", "").lower().endswith(".apk")]

    return {
        "emulatorId": "lemuroid",
        "version": tag,
        "name": name,
        "publishDate": format_date(published_at),
        "publishDateRaw": published_at,
        "author": author,
        "commitSha": commit_sha,
        "commitShaFull": commit_sha_full,
        "commitDate": format_date(commit_date),
        "htmlUrl": html_url,
        "isPrerelease": is_prerelease,
        "isLatest": True,
        "releaseNotes": body,
        "assets": [
            {
                "name": a.get("name", ""),
                "sizeMB": round(a.get("size", 0) / 1048576, 2),
                "downloadCount": a.get("download_count", 0),
                "url": a.get("browser_download_url", ""),
            }
            for a in assets
        ],
        "apkDownloadUrl": apk_assets[0]["browser_download_url"] if apk_assets else None,
        "fetchedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def print_summary(info):
    """以表格形式打印版本信息（模拟截图2的 GitHub Releases 页面）。"""
    print("=" * 60)
    print("  📋 Lemuroid 版本信息")
    print(f"  来源: {OWNER}/{REPO} Releases")
    print("=" * 60)
    print()
    print(f"  版本号     :  {info['version']}  {'✅ Latest' if info['isLatest'] else ''}")
    print(f"  发布状态   :  {'Pre-release' if info['isPrerelease'] else 'Latest (最新)'}")
    print(f"  发布者     :  {info['author']}")
    print(f"  发布日期   :  {info['publishDate']}")
    print(f"  Tag        :  {info['version']}")
    print(f"  Commit     :  {info['commitSha']}")
    print(f"  提交日期   :  {info['commitDate']}")
    print(f"  Release URL:  {info['htmlUrl']}")
    if info["apkDownloadUrl"]:
        print(f"  APK 下载   :  {info['apkDownloadUrl']}")
    print()
    print("-" * 60)
    print("  📝 更新日志 (Release Notes / Changelog)")
    print("-" * 60)
    for line in info["releaseNotes"].strip().split("\n"):
        print(f"  {line}")
    print()
    print("-" * 60)
    print("  📦 Release Assets")
    print("-" * 60)
    if info["assets"]:
        print(f"  {'文件名':<45} {'大小':>8}  {'下载次数':>8}")
        print(f"  {'-'*45} {'-'*8}  {'-'*8}")
        for a in info["assets"]:
            print(f"  {a['name']:<45} {a['sizeMB']:>6.2f}MB  {a['downloadCount']:>8}")
    else:
        print("  (无 Release Assets)")
    print()
    print(f"  ⏰ 检查时间: {info['fetchedAt']}")
    print("=" * 60)


def save_json(info, path):
    """保存版本缓存 JSON。"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    cache = {
        "emulatorId": info["emulatorId"],
        "version": info["version"],
        "releaseDate": info["publishDate"],
        "releaseNotes": info["releaseNotes"],
        "author": info["author"],
        "commitSha": info["commitSha"],
        "commitDate": info["commitDate"],
        "htmlUrl": info["htmlUrl"],
        "downloadUrl": info["apkDownloadUrl"],
        "fetchedAt": info["fetchedAt"],
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False, indent=2)
    print(f"\n✅ 版本缓存已保存到: {path}")


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""

    try:
        info = extract_version_info()
    except HTTPError as e:
        print(f"❌ GitHub API 错误: {e.code} {e.reason}", file=sys.stderr)
        sys.exit(1)
    except URLError as e:
        print(f"❌ 网络错误: {e}", file=sys.stderr)
        sys.exit(1)

    if mode == "--json":
        print(json.dumps(info, ensure_ascii=False, indent=2))
    elif mode == "--save":
        print_summary(info)
        script_dir = os.path.dirname(os.path.abspath(__file__))
        repo_root = os.path.dirname(script_dir)
        save_json(info, os.path.join(repo_root, "assets", "version_cache", "lemuroid.json"))
    else:
        print_summary(info)


if __name__ == "__main__":
    main()
