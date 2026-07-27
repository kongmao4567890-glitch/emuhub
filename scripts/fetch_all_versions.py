#!/usr/bin/env python3
"""
fetch_all_versions.py
=====================
读取 emulators.json 中所有模拟器，
通过 GitHub / GitLab / Forgejo API 获取每个模拟器的：
  - 版本号 (version / tag)
  - 发布日期 (release date)
  - 更新说明 (release notes / changelog)
  - commit SHA
  - APK 下载链接

按仓库去重（同一仓库只请求一次），结果写入 assets/version_cache/ 目录。

策略（GitHub，按优先级）：
1. releases/latest API — 有 "latest" 标记的仓库
2. releases?per_page=1 — 有 release 但无 latest 标记
3. tags?per_page=1 — 完全无 release，用最新 tag
4. commits?per_page=1 — 无 release 且无 tag，用最新 commit

当 release body 为空时，自动从对应 commit message 获取更新说明。

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
from urllib.parse import urlparse, quote
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

EMULATORS_JSON = "assets/emulators.json"
VERSION_CACHE_DIR = "assets/version_cache"


# ─── HTTP 工具 ───────────────────────────────────────────────

def make_headers(token=None, platform="github"):
    """构建 API 请求头。"""
    headers = {
        "Accept": "application/vnd.github+json" if platform == "github" else "application/json",
        "User-Agent": "emuhub-version-fetcher",
    }
    if platform == "github":
        headers["X-GitHub-Api-Version"] = "2022-11-28"
    if token:
        if platform == "github":
            headers["Authorization"] = f"Bearer {token}"
        elif platform == "gitlab":
            headers["Authorization"] = f"Bearer {token}"
        elif platform == "forgejo":
            headers["Authorization"] = f"token {token}"
    return headers


def fetch_json(url, token=None, platform="github", timeout=15):
    """获取 JSON API，返回解析后的 dict/list。"""
    req = Request(url, headers=make_headers(token, platform))
    with urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


# ─── 通用工具 ────────────────────────────────────────────────

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
    if not s:
        return False
    return bool(re.search(r"\d+\.\d+", s))


def is_valid_version(s):
    """判断字符串是否是一个有效的版本号。
    
    排除 "Pre-release", "CI-xxx", "latest", "release9" 等非版本号。
    """
    if not s:
        return False
    s_lower = s.lower()
    # 排除明显不是版本号的
    invalid_keywords = ["pre-release", "prerelease", "ci-", "latest", "nightly", "snapshot"]
    for kw in invalid_keywords:
        if kw in s_lower:
            return False
    # 必须包含数字和点
    return is_version_like(s)


def extract_version(tag, name):
    """从 tag_name 或 name 中提取版本号。

    某些仓库的 tag 是 "latest" 或非版本号，此时尝试从 name 中提取。
    """
    # 优先用 tag（如果是有效版本号）
    if tag and is_valid_version(tag):
        return strip_v_prefix(tag)

    # tag 不是版本号，尝试从 name 中提取
    for source in [name, tag]:
        if not source:
            continue
        # 匹配 v1.2.3 或 1.2.3（含可选的 build 号）
        match = re.search(r"v?(\d+\.\d+(?:\.\d+)*(?:\.\d+)?)", source)
        if match:
            return match.group(1)

    # 如果 tag 不是版本号但存在，返回空（不用错误值）
    if tag and not is_valid_version(tag):
        # 尝试从 tag 中提取数字部分
        match = re.search(r"(\d+\.\d+(?:\.\d+)*)", tag)
        if match:
            return match.group(1)
        return ""  # 无法提取版本号

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
        url = asset.get("browser_download_url", "") or asset.get("url", "")
        if not url or not name.endswith(".apk"):
            continue
        if any(k in name for k in ("arm64", "aarch64", "arm64-v8a")):
            arm64_apk = url
        any_apk = any_apk or url
    return arm64_apk or any_apk or ""


def fetch_mame_whatsnew(version):
    """从 mamedev.org 获取 MAME 版本的 whatsnew.txt 更新说明。

    MAME 的 GitHub releases body 始终为空，更新说明发布在官网。
    URL 格式: https://www.mamedev.org/releases/whatsnew_XXXX.txt
    其中 XXXX 是版本号去点（如 0.288 -> 0288）。
    """
    if not version:
        return ""
    # 去除版本号中的点和前缀
    ver_clean = version.replace(".", "")
    # 补零到 4 位（如 0288）
    ver_clean = ver_clean.zfill(4)
    url = f"https://www.mamedev.org/releases/whatsnew_{ver_clean}.txt"
    try:
        req = Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urlopen(req, timeout=20) as resp:
            content = resp.read().decode("utf-8", errors="replace")
        # whatsnew.txt 可能很长，截取前 3000 字符作为更新说明
        if len(content) > 3000:
            # 找到一个合适的截断点（段落结束）
            truncated = content[:3000]
            last_para = truncated.rfind("\n\n")
            if last_para > 1000:
                content = truncated[:last_para] + "\n\n... (完整更新说明请访问 mamedev.org)"
            else:
                content = truncated + "\n\n... (完整更新说明请访问 mamedev.org)"
        return content.strip()
    except Exception:
        return ""


def fetch_text(url, timeout=15):
    """获取 URL 的纯文本内容。"""
    req = Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


def parse_repo_url(url):
    """从 URL 解析出平台和 (owner, repo) 或项目路径。"""
    if not url:
        return None
    try:
        parts = urlparse(url)
        host = parts.netloc.lower()
        segments = [s for s in parts.path.split("/") if s]
        if len(segments) < 2:
            return None

        if "github.com" in host:
            owner = segments[0]
            repo = segments[1].replace(".git", "")
            return ("github", owner, repo)
        elif "gitlab.com" in host:
            # GitLab 项目路径可能是 owner/repo 或 group/subgroup/repo
            project_path = "/".join(segments)
            return ("gitlab", project_path, None)
        elif "eden-emu.dev" in host or "forgejo" in host:
            # Forgejo 实例
            owner = segments[0] if len(segments) > 0 else ""
            repo = segments[1] if len(segments) > 1 else ""
            return ("forgejo", owner, repo)
        else:
            return None
    except Exception:
        return None


# ─── GitHub API 策略 ────────────────────────────────────────

def fetch_commit_message_github(owner, repo, ref, token=None):
    """获取 GitHub 仓库指定 ref (tag/sha) 的 commit 信息（SHA + 日期 + message）。
    
    ref 可以是 tag name 或 commit SHA。
    """
    api_base = f"https://api.github.com/repos/{owner}/{repo}"
    
    # 先尝试作为 tag 获取 ref
    sha = ref
    try:
        ref_data = fetch_json(f"{api_base}/git/refs/tags/{ref}", token)
        obj = ref_data.get("object", {})
        sha = obj.get("sha", ref)
    except (HTTPError, URLError):
        pass  # ref 可能已经是 SHA

    # 获取 commit 详情
    try:
        commit = fetch_json(f"{api_base}/commits/{sha}", token)
        commit_data = commit.get("commit", {})
        message = commit_data.get("message", "")
        date = commit_data.get("committer", {}).get("date", "")
        # commit API 返回的 sha 字段
        full_sha = commit.get("sha", sha)
        return {
            "sha": full_sha[:7] if full_sha else "",
            "date": date,
            "message": message,
        }
    except (HTTPError, URLError):
        return None


def fetch_latest_commit_github(owner, repo, token=None):
    """策略 4：获取仓库最新 commit（当无 releases 和 tags 时）。"""
    api_base = f"https://api.github.com/repos/{owner}/{repo}"
    try:
        commits = fetch_json(f"{api_base}/commits?per_page=1", token)
        if commits and isinstance(commits, list) and len(commits) > 0:
            commit = commits[0]
            full_sha = commit.get("sha", "")
            commit_data = commit.get("commit", {})
            message = commit_data.get("message", "")
            date = commit_data.get("committer", {}).get("date", "")
            author = commit.get("author", {})
            author_login = author.get("login", "") if isinstance(author, dict) else ""
            
            return {
                "sha": full_sha[:7] if full_sha else "",
                "date": date,
                "message": message,
                "author": author_login,
            }
    except (HTTPError, URLError):
        pass
    return None


def _process_release(rel, owner, repo, token=None):
    """处理单个 release 对象，返回填充后的 result dict。
    
    如果 release body 为空，自动从 commit message 获取更新说明。
    """
    tag = rel.get("tag_name", "")
    name = rel.get("name", "")
    version = extract_version(tag, name)
    body = rel.get("body", "") or ""
    
    result = {
        "tag": tag,
        "version": version,
        "releaseDate": format_date(rel.get("published_at", "")),
        "releaseNotes": body,
        "author": rel.get("author", {}).get("login", ""),
        "htmlUrl": rel.get("html_url", ""),
        "downloadUrl": extract_apk_url(rel),
        "hasRelease": True,
        "commitSha": "",
        "commitDate": "",
    }
    
    # MAME 特殊处理：GitHub releases body 始终为空，从 mamedev.org 获取 whatsnew
    if not body and owner == "mamedev" and repo == "mame" and version:
        whatsnew = fetch_mame_whatsnew(version)
        if whatsnew:
            result["releaseNotes"] = whatsnew
            return result

    # 获取 commit 信息
    if tag:
        commit_info = fetch_commit_message_github(owner, repo, tag, token)
        if commit_info:
            result["commitSha"] = commit_info["sha"]
            result["commitDate"] = format_date(commit_info["date"])
            # 如果 release body 为空，使用 commit message 作为更新说明
            if not result.get("releaseNotes") and commit_info["message"]:
                result["releaseNotes"] = commit_info["message"]

    return result


def fetch_release_for_repo(owner, repo, token=None):
    """获取单个 GitHub 仓库的最新版本信息（版本号+更新说明+commit+APK）。

    策略（按优先级）：
    1. releases/latest API — 有 "latest" 标记的仓库
    2. releases?per_page=10 — 遍历 releases 找到第一个有有效版本号的
    3. tags?per_page=5 — 遍历 tags 找到第一个有有效版本号的
    4. commits?per_page=1 — 无 release 且无 tag，用最新 commit

    关键改进：当 tag 不是有效版本号（如 "latest", "preview", "Pre-release"）时，
    不会直接返回空版本，而是继续尝试下一个策略。
    之前策略获取的 releaseNotes 会保留。
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
    
    # 保存从 release 中获取的 notes（即使版本号为空也保留）
    fallback_notes = ""
    fallback_date = ""
    fallback_author = ""
    fallback_htmlurl = ""
    fallback_download = ""
    has_fallback = False

    # ─── 策略 1: releases/latest ───────────────────────────
    try:
        rel = fetch_json(f"{api_base}/releases/latest", token)
        rel_result = _process_release(rel, owner, repo, token)
        
        if rel_result["version"]:
            # 版本号有效，直接返回
            result.update(rel_result)
            return result
        else:
            # 版本号无效（tag 是 "latest"/"preview" 等），保存信息并继续
            fallback_notes = rel_result["releaseNotes"]
            fallback_date = rel_result["releaseDate"]
            fallback_author = rel_result["author"]
            fallback_htmlurl = rel_result["htmlUrl"]
            fallback_download = rel_result["downloadUrl"]
            has_fallback = True
            # 保存 commit 信息
            result["commitSha"] = rel_result["commitSha"]
            result["commitDate"] = rel_result["commitDate"]
    except HTTPError as e:
        if e.code == 404:
            pass  # 无 latest release，继续策略 2
        elif e.code == 403:
            result["error"] = "rate_limited"
            return result
        else:
            result["error"] = f"http_{e.code}"
            return result
    except URLError as e:
        result["error"] = str(e)
        return result

    # ─── 策略 2: releases 列表（遍历找有效版本号）─────────
    try:
        releases = fetch_json(f"{api_base}/releases?per_page=10", token)
        if releases and isinstance(releases, list) and len(releases) > 0:
            for rel in releases:
                rel_result = _process_release(rel, owner, repo, token)
                
                if rel_result["version"]:
                    # 找到有效版本号
                    result.update(rel_result)
                    return result
                else:
                    # 保存第一个 release 的信息作为 fallback
                    if not has_fallback:
                        fallback_notes = rel_result["releaseNotes"]
                        fallback_date = rel_result["releaseDate"]
                        fallback_author = rel_result["author"]
                        fallback_htmlurl = rel_result["htmlUrl"]
                        fallback_download = rel_result["downloadUrl"]
                        has_fallback = True
                        result["commitSha"] = rel_result["commitSha"]
                        result["commitDate"] = rel_result["commitDate"]
    except HTTPError as e:
        if e.code == 403:
            result["error"] = "rate_limited"
            return result
    except (URLError, Exception):
        pass

    # ─── 策略 3: tags 列表（遍历找有效版本号）─────────────
    try:
        tags = fetch_json(f"{api_base}/tags?per_page=5", token)
        if tags and isinstance(tags, list) and len(tags) > 0:
            for tag_entry in tags:
                tag = tag_entry.get("name", "")
                version = extract_version(tag, "")
                
                if version:
                    # 找到有效版本号的 tag
                    result.update({
                        "tag": tag,
                        "version": version,
                        "hasRelease": False,
                    })
                    
                    # 获取 tag 对应 commit 的信息和 message
                    commit_sha = tag_entry.get("commit", {}).get("sha", "")
                    if commit_sha:
                        result["commitSha"] = commit_sha[:7]
                        try:
                            commit = fetch_json(f"{api_base}/commits/{commit_sha}", token)
                            commit_data = commit.get("commit", {})
                            result["commitDate"] = format_date(
                                commit_data.get("committer", {}).get("date", "")
                            )
                            # 使用 commit message 作为更新说明（如果之前没有获取到）
                            message = commit_data.get("message", "")
                            if message and not result.get("releaseNotes"):
                                result["releaseNotes"] = message
                        except (HTTPError, URLError):
                            pass
                    
                    # 如果没有 releaseNotes，使用 fallback
                    if not result["releaseNotes"] and fallback_notes:
                        result["releaseNotes"] = fallback_notes
                    if not result["releaseDate"]:
                        result["releaseDate"] = fallback_date
                    if not result["author"]:
                        result["author"] = fallback_author
                    if not result["htmlUrl"]:
                        result["htmlUrl"] = fallback_htmlurl
                    if not result["downloadUrl"]:
                        result["downloadUrl"] = fallback_download
                    
                    return result
    except HTTPError as e:
        if e.code == 403:
            result["error"] = "rate_limited"
            return result
    except (URLError, Exception):
        pass

    # ─── 策略 4: 最新 commit ───────────────────────────────
    commit_info = fetch_latest_commit_github(owner, repo, token)
    if commit_info:
        sha = commit_info["sha"]
        message = commit_info["message"]
        
        # 尝试从 commit message 中提取版本号
        version = ""
        if message:
            first_line = message.split("\n")[0].strip()
            version_match = re.search(r"v?(\d+\.\d+(?:\.\d+)*)", first_line)
            if version_match:
                version = version_match.group(1)
        
        if not version:
            version = f"commit-{sha}" if sha else "unknown"
        
        # 优先使用 fallback releaseNotes（来自之前策略的 release body）
        notes = fallback_notes if fallback_notes else message
        
        result.update({
            "tag": "",
            "version": version,
            "releaseDate": format_date(commit_info["date"]) if not fallback_date else fallback_date,
            "releaseNotes": notes,
            "author": commit_info.get("author", "") if not fallback_author else fallback_author,
            "commitSha": sha,
            "commitDate": format_date(commit_info["date"]),
            "htmlUrl": f"https://github.com/{owner}/{repo}/commit/{sha}" if not fallback_htmlurl else fallback_htmlurl,
            "downloadUrl": fallback_download,
            "hasRelease": has_fallback,
        })
        return result

    # 所有策略都失败，使用 fallback 信息
    if has_fallback:
        result.update({
            "version": "unknown",
            "releaseDate": fallback_date,
            "releaseNotes": fallback_notes,
            "author": fallback_author,
            "htmlUrl": fallback_htmlurl,
            "downloadUrl": fallback_download,
            "hasRelease": True,
        })

    return result


# ─── GitLab API 策略 ────────────────────────────────────────

def fetch_release_for_gitlab(project_path, token=None):
    """获取 GitLab 项目的最新版本信息。
    
    注意：GitLab API 不使用 GitHub token，公开项目无需认证。
    """
    encoded_path = quote(project_path, safe="")
    api_base = f"https://gitlab.com/api/v4/projects/{encoded_path}"
    # GitLab 不使用 GitHub token
    gitlab_token = None
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

    # 尝试获取 releases
    try:
        releases = fetch_json(f"{api_base}/releases", gitlab_token, platform="gitlab")
        if releases and isinstance(releases, list) and len(releases) > 0:
            rel = releases[0]
            tag = rel.get("tag_name", "")
            name = rel.get("name", "")
            version = extract_version(tag, name)
            
            # 从 assets/links 中提取下载链接
            download_url = ""
            links = rel.get("assets", {}).get("links", [])
            for link in links:
                url = link.get("url", "")
                if url and url.lower().endswith(".apk"):
                    download_url = url
                    break
            
            result.update({
                "tag": tag,
                "version": version,
                "releaseDate": format_date(rel.get("released_at", "")),
                "releaseNotes": rel.get("description", "") or "",
                "author": rel.get("author", {}).get("username", "") if isinstance(rel.get("author"), dict) else "",
                "htmlUrl": rel.get("_links", {}).get("self", "") if isinstance(rel.get("_links"), dict) else "",
                "downloadUrl": download_url,
                "hasRelease": True,
            })
            return result
    except HTTPError as e:
        if e.code == 404:
            pass  # 无 releases
        elif e.code == 403:
            result["error"] = "rate_limited"
            return result
    except (URLError, Exception):
        pass

    # 尝试获取 tags
    try:
        tags = fetch_json(f"{api_base}/repository/tags?per_page=1", gitlab_token, platform="gitlab")
        if tags and isinstance(tags, list) and len(tags) > 0:
            tag = tags[0].get("name", "")
            version = extract_version(tag, "")
            commit = tags[0].get("commit", {})
            
            result.update({
                "tag": tag,
                "version": version,
                "releaseNotes": commit.get("message", "") or "",
                "commitSha": commit.get("short_id", "")[:7] if commit.get("short_id") else "",
                "commitDate": format_date(commit.get("created_at", "")),
                "hasRelease": False,
            })
            return result
    except (HTTPError, URLError, Exception):
        pass

    # 尝试获取最新 commit
    try:
        commits = fetch_json(f"{api_base}/repository/commits?per_page=1", gitlab_token, platform="gitlab")
        if commits and isinstance(commits, list) and len(commits) > 0:
            commit = commits[0]
            sha = commit.get("short_id", "")[:7] if commit.get("short_id") else ""
            message = commit.get("message", "")
            
            version = ""
            if message:
                first_line = message.split("\n")[0].strip()
                version_match = re.search(r"v?(\d+\.\d+(?:\.\d+)*)", first_line)
                if version_match:
                    version = version_match.group(1)
            if not version:
                version = f"commit-{sha}" if sha else "unknown"
            
            result.update({
                "tag": "",
                "version": version,
                "releaseDate": format_date(commit.get("created_at", "")),
                "releaseNotes": message,
                "author": commit.get("author_name", ""),
                "commitSha": sha,
                "commitDate": format_date(commit.get("created_at", "")),
                "htmlUrl": commit.get("web_url", ""),
                "hasRelease": False,
            })
            return result
    except (HTTPError, URLError, Exception):
        pass

    return result


# ─── Forgejo API 策略 ───────────────────────────────────────

def fetch_release_for_forgejo(base_url, owner, repo, token=None):
    """获取 Forgejo 实例项目的最新版本信息。
    
    注意：Forgejo API 不使用 GitHub token，公开项目无需认证。
    """
    api_base = f"{base_url}/api/v1/repos/{owner}/{repo}"
    # Forgejo 不使用 GitHub token
    forgejo_token = None
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

    # 尝试获取 releases
    try:
        releases = fetch_json(f"{api_base}/releases?limit=1", forgejo_token, platform="forgejo")
        if releases and isinstance(releases, list) and len(releases) > 0:
            rel = releases[0]
            tag = rel.get("tag_name", "")
            name = rel.get("name", "")
            version = extract_version(tag, name)
            
            # 从 assets 中提取 APK
            download_url = ""
            for asset in rel.get("assets", []):
                url = asset.get("browser_download_url", "")
                name_lower = asset.get("name", "").lower()
                if url and name_lower.endswith(".apk"):
                    download_url = url
                    break
            
            result.update({
                "tag": tag,
                "version": version,
                "releaseDate": format_date(rel.get("published_at", "")),
                "releaseNotes": rel.get("body", "") or "",
                "author": rel.get("author", {}).get("login", "") if isinstance(rel.get("author"), dict) else "",
                "htmlUrl": rel.get("url", ""),
                "downloadUrl": download_url,
                "hasRelease": True,
            })
            return result
    except (HTTPError, URLError, Exception):
        pass

    # 尝试获取 tags
    try:
        tags = fetch_json(f"{api_base}/tags?limit=1", forgejo_token, platform="forgejo")
        if tags and isinstance(tags, list) and len(tags) > 0:
            tag = tags[0].get("name", "")
            version = extract_version(tag, "")
            commit = tags[0].get("commit", {})
            
            result.update({
                "tag": tag,
                "version": version,
                "releaseNotes": "",
                "commitSha": commit.get("sha", "")[:7] if commit.get("sha") else "",
                "commitDate": format_date(commit.get("created", "")),
                "hasRelease": False,
            })
            return result
    except (HTTPError, URLError, Exception):
        pass

    # 尝试获取最新 commit
    try:
        commits = fetch_json(f"{api_base}/commits?limit=1", forgejo_token, platform="forgejo")
        if commits and isinstance(commits, list) and len(commits) > 0:
            commit = commits[0]
            sha = commit.get("sha", "")[:7] if commit.get("sha") else ""
            message = commit.get("commit", {}).get("message", "")
            
            version = ""
            if message:
                first_line = message.split("\n")[0].strip()
                version_match = re.search(r"v?(\d+\.\d+(?:\.\d+)*)", first_line)
                if version_match:
                    version = version_match.group(1)
            if not version:
                version = f"commit-{sha}" if sha else "unknown"
            
            result.update({
                "tag": "",
                "version": version,
                "releaseDate": format_date(commit.get("commit", {}).get("date", "")),
                "releaseNotes": message,
                "author": commit.get("author", {}).get("login", "") if isinstance(commit.get("author"), dict) else "",
                "commitSha": sha,
                "commitDate": format_date(commit.get("commit", {}).get("date", "")),
                "htmlUrl": commit.get("html_url", ""),
                "hasRelease": False,
            })
            return result
    except (HTTPError, URLError, Exception):
        pass

    return result


# ─── 统一获取入口 ────────────────────────────────────────────

def fetch_release_for_source(source_info, token=None):
    """根据平台类型选择对应的获取策略。"""
    platform = source_info["platform"]
    
    if platform == "github":
        return fetch_release_for_repo(source_info["owner"], source_info["repo"], token)
    elif platform == "gitlab":
        return fetch_release_for_gitlab(source_info["project_path"], token)
    elif platform == "forgejo":
        return fetch_release_for_forgejo(
            source_info["base_url"], source_info["owner"], source_info["repo"], token
        )
    else:
        return {
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
            "error": f"unsupported_platform:{platform}",
        }


# ─── 加载模拟器 ──────────────────────────────────────────────

def load_emulators(json_path):
    """从 emulators.json 加载所有模拟器（含 GitHub 和非 GitHub 来源）。"""
    with open(json_path, encoding="utf-8") as f:
        data = json.load(f)

    emulators = []
    for console in data.get("consoles", []):
        for emu in console.get("emulators", []):
            source_url = emu.get("sourceUrl", "")
            source_type = emu.get("sourceType", "")
            
            # 解析 sourceUrl
            parsed = parse_repo_url(source_url)
            
            if parsed:
                platform, owner_or_path, repo = parsed
                if platform == "github":
                    emulators.append({
                        "id": emu["id"],
                        "name": emu["name"],
                        "core": emu.get("core", ""),
                        "platform": "github",
                        "owner": owner_or_path,
                        "repo": repo,
                        "sourceUrl": source_url,
                        "sourceType": source_type,
                    })
                elif platform == "gitlab":
                    emulators.append({
                        "id": emu["id"],
                        "name": emu["name"],
                        "core": emu.get("core", ""),
                        "platform": "gitlab",
                        "project_path": owner_or_path,
                        "sourceUrl": source_url,
                        "sourceType": source_type,
                    })
                elif platform == "forgejo":
                    # 从 URL 提取 base_url
                    parts = urlparse(source_url)
                    base_url = f"{parts.scheme}://{parts.netloc}"
                    emulators.append({
                        "id": emu["id"],
                        "name": emu["name"],
                        "core": emu.get("core", ""),
                        "platform": "forgejo",
                        "base_url": base_url,
                        "owner": owner_or_path,
                        "repo": repo,
                        "sourceUrl": source_url,
                        "sourceType": source_type,
                    })
            # 对于没有可解析 URL 的模拟器（如纯 Play Store），跳过
            # 这些模拟器在应用层通过其他方式获取版本信息

    return emulators


# ─── 主获取流程 ──────────────────────────────────────────────

def fetch_all(emulators, token=None, delay=0.3):
    """抓取所有模拟器的版本信息（按仓库去重）。"""
    repo_cache = {}
    repo_keys = []
    for emu in emulators:
        if emu["platform"] == "github":
            key = f"github:{emu['owner']}/{emu['repo']}"
        elif emu["platform"] == "gitlab":
            key = f"gitlab:{emu['project_path']}"
        elif emu["platform"] == "forgejo":
            key = f"forgejo:{emu['base_url']}/{emu['owner']}/{emu['repo']}"
        else:
            continue
        
        if key not in repo_cache:
            repo_cache[key] = None
            repo_keys.append((key, emu))

    print(f"📊 共 {len(emulators)} 个模拟器，{len(repo_keys)} 个唯一仓库", file=sys.stderr)

    results = {}
    fetched = 0
    failed = 0

    for i, (key, emu) in enumerate(repo_keys, 1):
        print(f"[{i}/{len(repo_keys)}] {key} ... ", end="", file=sys.stderr, flush=True)

        try:
            info = fetch_release_for_source(emu, token)
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
        if emu["platform"] == "github":
            key = f"github:{emu['owner']}/{emu['repo']}"
            repo_display = f"{emu['owner']}/{emu['repo']}"
        elif emu["platform"] == "gitlab":
            key = f"gitlab:{emu['project_path']}"
            repo_display = emu["project_path"]
        elif emu["platform"] == "forgejo":
            key = f"forgejo:{emu['base_url']}/{emu['owner']}/{emu['repo']}"
            repo_display = f"{emu['owner']}/{emu['repo']}"
        else:
            continue

        info = repo_cache.get(key, {})
        
        # 构建 htmlUrl 回退
        html_url = info.get("htmlUrl", "")
        if not html_url:
            if emu["platform"] == "github":
                html_url = f"https://github.com/{emu['owner']}/{emu['repo']}/releases"
            elif emu["platform"] == "gitlab":
                html_url = f"https://gitlab.com/{emu['project_path']}/-/releases"
            elif emu["platform"] == "forgejo":
                html_url = f"{emu['base_url']}/{emu['owner']}/{emu['repo']}/releases"

        results[emu["id"]] = {
            "emulatorId": emu["id"],
            "name": emu["name"],
            "core": emu["core"],
            "repo": repo_display,
            "platform": emu["platform"],
            "version": info.get("version", ""),
            "tag": info.get("tag", ""),
            "releaseDate": info.get("releaseDate", ""),
            "releaseNotes": info.get("releaseNotes", ""),
            "author": info.get("author", ""),
            "commitSha": info.get("commitSha", ""),
            "commitDate": info.get("commitDate", ""),
            "htmlUrl": html_url,
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
            "source": info.get("platform", "github-api"),
            "fetchedAt": info["fetchedAt"],
        }
        with open(path, "w", encoding="utf-8") as f:
            json.dump(cache, f, ensure_ascii=False, indent=2)
        saved += 1
    return saved


def create_placeholder_caches(emulators_json, cache_dir):
    """为没有 GitHub/GitLab/Forgejo 来源的模拟器创建占位缓存文件。

    处理 Play Store、Website 等类型的模拟器，确保每个模拟器都有缓存文件。
    """
    with open(emulators_json, encoding="utf-8") as f:
        data = json.load(f)

    os.makedirs(cache_dir, exist_ok=True)
    created = 0
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    for console in data.get("consoles", []):
        for emu in console.get("emulators", []):
            emu_id = emu["id"]
            cache_path = os.path.join(cache_dir, f"{emu_id}.json")

            # 如果缓存文件已存在，跳过
            if os.path.exists(cache_path):
                continue

            source_type = emu.get("sourceType", "")
            source_url = emu.get("sourceUrl", "")
            name = emu.get("name", "")

            # 尝试从 website URL 中提取版本信息
            version = ""
            release_notes = ""
            html_url = source_url
            release_date = ""

            if source_type == "playstore":
                version = "Play Store"
                release_notes = "此模拟器可通过 Google Play 商店获取，请前往 Play 商店查看最新版本信息。"
            elif source_type == "website":
                # 尝试从 F-Droid 获取版本信息
                if "f-droid.org" in source_url:
                    try:
                        package = source_url.rstrip("/").split("/")[-1]
                        fdroid_url = f"https://f-droid.org/api/v1/packages/{package}"
                        fdroid_data = fetch_json(fdroid_url, platform="gitlab")
                        packages = fdroid_data.get("packages", [])
                        if packages:
                            version = packages[0].get("versionName", "")
                            release_date = format_date(fdroid_data.get("currentVersionDate", ""))
                        release_notes = fdroid_data.get("whatsNew", "") or "请前往 F-Droid 查看最新版本信息。"
                    except Exception:
                        version = "F-Droid"
                        release_notes = "此模拟器可通过 F-Droid 获取，请前往 F-Droid 查看最新版本信息。"
                # 尝试从 SourceForge 获取版本信息
                elif "sourceforge.net" in source_url:
                    try:
                        project = source_url.rstrip("/").split("/")[-1] if "/projects/" in source_url else ""
                        if not project:
                            project = source_url.rstrip("/").split("/")[-1]
                        sf_url = f"https://sourceforge.net/projects/{project}/best_release.json"
                        sf_data = fetch_json(sf_url, platform="gitlab")
                        release = sf_data.get("release", {})
                        version = release.get("filename", "").split("-")[-1].replace(".zip", "").replace(".tar.gz", "").replace(".apk", "")
                        if not is_version_like(version):
                            version = "SourceForge"
                        release_notes = f"请前往 SourceForge 项目页面查看最新版本信息。"
                        html_url = f"https://sourceforge.net/projects/{project}/"
                    except Exception:
                        version = "SourceForge"
                        release_notes = "此模拟器可通过 SourceForge 获取，请前往 SourceForge 查看最新版本信息。"
                else:
                    version = "官网"
                    release_notes = "此模拟器可通过官方网站获取，请前往官网查看最新版本信息。"
            else:
                version = "未知"
                release_notes = "无法自动获取此模拟器的版本信息。"

            cache = {
                "emulatorId": emu_id,
                "version": version,
                "releaseDate": release_date,
                "releaseNotes": release_notes,
                "author": "",
                "commitSha": "",
                "commitDate": "",
                "htmlUrl": html_url,
                "downloadUrl": "",
                "source": source_type,
                "fetchedAt": now,
            }
            with open(cache_path, "w", encoding="utf-8") as f:
                json.dump(cache, f, ensure_ascii=False, indent=2)
            created += 1
            print(f"  📄 创建占位缓存: {emu_id} ({name}) -> {version}", file=sys.stderr)

    return created


def print_summary(results, fetched, failed):
    """打印摘要表格。"""
    print("=" * 90)
    print(f"  📋 全部模拟器版本信息（版本号 + 更新说明）")
    print(f"  仓库成功: {fetched} | 失败: {failed} | 模拟器总数: {len(results)}")
    print("=" * 90)
    print()

    with_version = [(k, v) for k, v in results.items() if v["version"]]
    without_version = [(k, v) for k, v in results.items() if not v["version"]]

    print(f"{'模拟器名称':<35s} {'版本':<20s} {'发布日期':<12s} {'更新说明':<6s} {'仓库'}")
    print("-" * 90)
    for emu_id, info in sorted(with_version, key=lambda x: x[1]["name"]):
        has_notes = "✅ 有" if info["releaseNotes"] else "❌ 无"
        ver_display = info["version"][:18] if info["version"] else "N/A"
        print(f"{info['name']:<35s} {ver_display:<20s} {info['releaseDate']:<12s} {has_notes:<6s} {info['repo']}")

    if without_version:
        print(f"\n⚠️ 未获取到版本的模拟器 ({len(without_version)}):")
        for emu_id, info in sorted(without_version, key=lambda x: x[1]["name"]):
            print(f"  {info['name']:<35s} ({info['repo']})")

    # 统计
    with_notes = sum(1 for v in results.values() if v["releaseNotes"])
    print(f"\n📈 统计:")
    print(f"  有版本号: {len(with_version)}/{len(results)}")
    print(f"  有更新说明: {with_notes}/{len(results)}")
    print(f"  版本+说明齐全: {sum(1 for v in results.values() if v['version'] and v['releaseNotes'])}/{len(results)}")

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
    print(f"📦 加载了 {len(emulators)} 个模拟器", file=sys.stderr)

    results, fetched, failed = fetch_all(emulators, token, args.delay)

    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
    elif args.save:
        print_summary(results, fetched, failed)
        saved = save_version_cache(results, VERSION_CACHE_DIR)
        print(f"\n✅ 已保存 {saved} 个版本缓存到 {VERSION_CACHE_DIR}/")
        # 为没有 API 来源的模拟器创建占位缓存
        placeholders = create_placeholder_caches(args.emulators_json, VERSION_CACHE_DIR)
        if placeholders > 0:
            print(f"📄 已创建 {placeholders} 个占位缓存（Play Store / Website 来源）")
    else:
        print_summary(results, fetched, failed)


if __name__ == "__main__":
    main()
