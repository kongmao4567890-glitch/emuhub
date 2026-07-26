#!/usr/bin/env python3
"""
scrape_release_page.py
======================
通过读取 GitHub Releases 目标网页数据，提取模拟器版本信息并更新软件版本缓存。

工作方式：
  1. 读取 GitHub Releases 网页 HTML（https://github.com/{owner}/{repo}/releases）
  2. 从 HTML 中提取版本号、发布日期、更新日志等
  3. 回退到 GitHub API 补充 commit SHA、APK 下载链接等网页未直接展示的字段
  4. 生成版本缓存 JSON，供 App 离线回退使用

用法:
    python3 scrape_release_page.py                          # 打印版本信息
    python3 scrape_release_page.py --owner Swordfish90 --repo Lemuroid
    python3 scrape_release_page.py --save                    # 保存到 version_cache
    python3 scrape_release_page.py --json                    # 输出 JSON
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from html.parser import HTMLParser
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

HEADERS = {
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "User-Agent": "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 emuhub-version-fetcher",
}

API_HEADERS = {
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "emuhub-version-fetcher",
}


def fetch_url(url, headers=None, timeout=15):
    """获取 URL 内容。"""
    req = Request(url, headers=headers or HEADERS)
    with urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


def fetch_json(url, headers=None, timeout=15):
    """获取 JSON API。"""
    req = Request(url, headers=headers or API_HEADERS)
    with urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


class ReleasePageParser(HTMLParser):
    """从 GitHub Releases 网页 HTML 中提取版本信息。

    GitHub Releases 页面结构（2024-2026 版本）:
    - 版本号在 <h2> 或 <h1> 标签中，带 data-view-component
    - "Latest" 徽章在 <span> 中
    - 发布日期在 <relative-time> 或 <time> 标签中
    - 更新日志在 release-body / markdown-body div 中
    """

    def __init__(self):
        super().__init__()
        self.releases = []
        self._current_release = None
        self._in_section = False
        self._in_body = False
        self._in_tag = ""
        self._text_buffer = []
        self._depth = 0

    def handle_starttag(self, tag, attrs):
        attrs_dict = dict(attrs)

        # 检测 release section 开始
        cls = attrs_dict.get("class", "")
        if "release" in cls and "entry" in cls:
            self._current_release = {
                "version": "",
                "is_latest": False,
                "date": "",
                "body": "",
                "tag": "",
            }
            self._in_section = True
            self._depth = 0

        if self._in_section:
            self._depth += 1

            # 版本号 - 在 section 标题的链接中
            if tag == "a" and "/releases/tag/" in attrs_dict.get("href", ""):
                href = attrs_dict["href"]
                match = re.search(r"/releases/tag/(.+?)(?:\?|#|$)", href)
                if match and self._current_release:
                    self._current_release["tag"] = match.group(1)
                    self._current_release["version"] = match.group(1).lstrip("vV")

            # "Latest" 徽章
            if tag == "span" and "Latest" in cls:
                if self._current_release:
                    self._current_release["is_latest"] = True

            # 发布日期 - relative-time 或 time 标签
            if tag in ("relative-time", "time"):
                dt = attrs_dict.get("datetime", "")
                if dt and self._current_release and not self._current_release["date"]:
                    self._current_release["date"] = dt

            # 更新日志正文
            if "markdown-body" in cls or ("release-body" in cls):
                self._in_body = True
                self._text_buffer = []

    def handle_endtag(self, tag):
        if self._in_section:
            self._depth -= 1

            if self._in_body and tag in ("div", "section"):
                if self._text_buffer:
                    if self._current_release:
                        self._current_release["body"] = "\n".join(
                            self._text_buffer
                        ).strip()
                self._in_body = False

            if self._depth <= 0:
                # section 结束
                if self._current_release and self._current_release["version"]:
                    self.releases.append(self._current_release)
                self._current_release = None
                self._in_section = False
                self._in_body = False

    def handle_data(self, data):
        if self._in_body:
            text = data.strip()
            if text:
                self._text_buffer.append(text)


def scrape_releases_page(owner, repo):
    """读取 GitHub Releases 网页 HTML，提取版本信息。"""
    url = f"https://github.com/{owner}/{repo}/releases"
    print(f"📖 读取网页: {url}", file=sys.stderr)

    html = fetch_url(url)

    parser = ReleasePageParser()
    parser.feed(html)

    if not parser.releases:
        # 回退：尝试从 HTML 中用正则提取
        return scrape_via_regex(html, owner, repo)

    # 取第一个 release（页面按时间倒序排列）
    latest = parser.releases[0]
    return latest, url


def scrape_via_regex(html, owner, repo):
    """正则回退方案：从 HTML 中提取版本信息。"""

    # 版本号 - 从 /releases/tag/x.y.z 链接提取
    tag_match = re.search(r'/releases/tag/([^"\'?#]+)', html)
    tag = tag_match.group(1) if tag_match else ""
    version = tag.lstrip("vV") if tag else ""

    # 发布日期 - 从 relative-time 或 time datetime 属性提取
    date_match = re.search(r'<(?:relative-)?time[^>]+datetime="([^"]+)"', html)
    date_raw = date_match.group(1) if date_match else ""

    # 更新日志 - 从 markdown-body 中提取
    body_match = re.search(
        r'<div[^>]*class="[^"]*markdown-body[^"]*"[^>]*>(.*?)</div>',
        html,
        re.DOTALL,
    )
    body = ""
    if body_match:
        # 清理 HTML 标签
        raw_body = body_match.group(1)
        body = re.sub(r"<[^>]+>", "\n", raw_body)
        body = re.sub(r"\n{3,}", "\n\n", body).strip()

    # Latest 徽章
    is_latest = "Latest" in html

    return {
        "version": version,
        "tag": tag,
        "is_latest": is_latest,
        "date": date_raw,
        "body": body or "无更新说明",
    }, f"https://github.com/{owner}/{repo}/releases"


def supplement_with_api(owner, repo, release_info):
    """用 GitHub API 补充网页未展示的字段（commit SHA、APK 下载链接）。

    网页 HTML 不直接包含 commit SHA 和 asset 下载链接的完整信息，
    需要通过 API 补充。如果 API 限流则跳过，仅使用网页数据。
    """
    api_base = f"https://api.github.com/repos/{owner}/{repo}"
    tag = release_info.get("tag", "")

    result = {
        **release_info,
        "commitSha": None,
        "commitDate": None,
        "apkUrl": None,
        "author": None,
        "htmlUrl": None,
    }

    try:
        # 获取 release 详情（含 assets）
        if tag:
            release_api = fetch_json(f"{api_base}/releases/tags/{tag}")
            result["author"] = release_api.get("author", {}).get("login", "")
            result["htmlUrl"] = release_api.get("html_url", "")

            # 提取 APK 下载链接
            assets = release_api.get("assets", [])
            for asset in assets:
                name = asset.get("name", "").lower()
                if name.endswith(".apk"):
                    result["apkUrl"] = asset.get("browser_download_url", "")
                    break

            # 如果网页未提取到 body，用 API 的
            if not release_info.get("body") or release_info["body"] == "无更新说明":
                result["body"] = release_api.get("body", "无更新说明") or "无更新说明"

        # 获取 tag 对应的 commit SHA
        if tag:
            try:
                tag_ref = fetch_json(f"{api_base}/git/refs/tags/{tag}")
                commit_sha_full = tag_ref["object"]["sha"]
                result["commitSha"] = commit_sha_full[:7]
                result["commitShaFull"] = commit_sha_full

                # 获取 commit 日期
                commit_info = fetch_json(f"{api_base}/commits/{commit_sha_full}")
                result["commitDate"] = (
                    commit_info.get("commit", {})
                    .get("committer", {})
                    .get("date", "")
                )
            except (HTTPError, URLError, KeyError):
                pass

    except (HTTPError, URLError):
        # API 限流或失败，仅使用网页数据
        print("⚠️ API 补充失败（可能限流），仅使用网页数据", file=sys.stderr)

    return result


def format_date(iso_str):
    """ISO 8601 -> YYYY-MM-DD。"""
    if not iso_str:
        return ""
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        return dt.strftime("%Y-%m-%d")
    except Exception:
        return iso_str[:10] if len(iso_str) >= 10 else iso_str


def build_version_cache(owner, repo, info):
    """构建版本缓存 JSON（供 App 读取）。"""
    return {
        "emulatorId": "lemuroid",
        "version": info.get("version", ""),
        "releaseDate": format_date(info.get("date", "")),
        "releaseNotes": info.get("body", "无更新说明"),
        "author": info.get("author", ""),
        "commitSha": info.get("commitSha", ""),
        "commitDate": format_date(info.get("commitDate", "")),
        "htmlUrl": info.get("htmlUrl", "") or f"https://github.com/{owner}/{repo}/releases",
        "downloadUrl": info.get("apkUrl", ""),
        "source": "webpage",
        "fetchedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def print_summary(owner, repo, info):
    """打印版本信息摘要。"""
    print("=" * 60)
    print("  📋 Lemuroid 版本信息（通过读取网页数据获取）")
    print(f"  来源: github.com/{owner}/{repo}/releases")
    print("=" * 60)
    print()
    print(f"  版本号     :  {info.get('version', '?')}  {'✅ Latest' if info.get('is_latest') else ''}")
    print(f"  发布者     :  {info.get('author', 'N/A')}")
    print(f"  发布日期   :  {format_date(info.get('date', ''))}")
    print(f"  Tag        :  {info.get('tag', '?')}")
    print(f"  Commit     :  {info.get('commitSha', 'N/A')}")
    print(f"  提交日期   :  {format_date(info.get('commitDate', ''))}")
    if info.get("apkUrl"):
        print(f"  APK 下载   :  {info['apkUrl']}")
    print()
    print("-" * 60)
    print("  📝 更新日志")
    print("-" * 60)
    for line in (info.get("body") or "无更新说明").strip().split("\n"):
        print(f"  {line}")
    print()
    print(f"  ⏰ 获取时间: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}")
    print("=" * 60)


def main():
    parser = argparse.ArgumentParser(description="读取 GitHub Releases 网页数据提取版本信息")
    parser.add_argument("--owner", default="Swordfish90", help="仓库 owner")
    parser.add_argument("--repo", default="Lemuroid", help="仓库名")
    parser.add_argument("--save", action="store_true", help="保存到 version_cache JSON")
    parser.add_argument("--json", action="store_true", help="输出 JSON")
    args = parser.parse_args()

    # 1. 读取网页数据
    release_info, page_url = scrape_releases_page(args.owner, args.repo)

    # 2. 用 API 补充字段
    release_info = supplement_with_api(args.owner, args.repo, release_info)

    # 3. 构建版本缓存
    cache = build_version_cache(args.owner, args.repo, release_info)

    if args.json:
        print(json.dumps(cache, ensure_ascii=False, indent=2))
    elif args.save:
        print_summary(args.owner, args.repo, release_info)
        script_dir = os.path.dirname(os.path.abspath(__file__))
        repo_root = os.path.dirname(script_dir)
        cache_path = os.path.join(repo_root, "assets", "version_cache", "lemuroid.json")
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        with open(cache_path, "w", encoding="utf-8") as f:
            json.dump(cache, f, ensure_ascii=False, indent=2)
        print(f"\n✅ 版本缓存已保存到: {cache_path}")
    else:
        print_summary(args.owner, args.repo, release_info)


if __name__ == "__main__":
    main()
