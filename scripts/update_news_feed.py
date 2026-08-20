#!/usr/bin/env python3
"""Build the Chinese EmuHub news feed from Emu-France's official RSS.

The app never translates articles on the phone.  This job fetches the feed,
extracts useful metadata from each article, translates new or changed content,
and merges it with the previous 90-day snapshot.  Only Python's standard
library is used so the script can run in GitHub Actions without setup work.
"""

from __future__ import annotations

import argparse
import hashlib
import html
from html.parser import HTMLParser
import json
import re
import sys
import time
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlencode, urljoin
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
ASSET_PATH = ROOT / "assets" / "news.json"
DATA_PATH = ROOT / "data" / "news.json"
FEED_URL = "https://www.emu-france.com/flux/rss/"
SOURCE_URL = "https://www.emu-france.com/"
RETENTION_DAYS = 90
ANDROID_NEWS_LIMIT = 30
ANDROID_NEWS_PREFIX = "android-release-"
ANDROID_TRANSLATION_VERSION = 2
USER_AGENT = (
    "EmuHub-News/1.0 (+https://github.com/kongmao4567890-glitch/emuhub)"
)

CATEGORY_RULES: tuple[tuple[str, str, str], ...] = (
    ("utilitaire", "tools", "工具"),
    ("driver", "driver", "驱动"),
    ("pilote", "driver", "驱动"),
    ("console portable", "handheld", "掌机"),
    ("console de salon", "home_console", "家用机"),
    ("consoles de salon", "home_console", "家用机"),
    ("arcade", "arcade", "街机"),
    ("ordi", "computer", "电脑"),
    ("ordinateur", "computer", "电脑"),
    ("multi", "multi_system", "多系统"),
    ("pda", "mobile", "移动设备"),
    ("tel", "mobile", "移动设备"),
)


def fetch(url: str, timeout: int = 30) -> bytes:
    request = Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "application/rss+xml, application/xml, text/html;q=0.9, */*;q=0.5",
        },
    )
    with urlopen(request, timeout=timeout) as response:
        return response.read()


class TextExtractor(HTMLParser):
    """Turn article HTML into readable plain text with stable paragraphs."""

    block_tags = {
        "p", "div", "section", "article", "h1", "h2", "h3", "h4",
        "blockquote", "pre", "ul", "ol", "table", "tr",
    }

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.skip_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in {"script", "style", "noscript"}:
            self.skip_depth += 1
        elif self.skip_depth == 0:
            if tag == "br":
                self.parts.append("\n")
            elif tag == "li":
                self.parts.append("\n• ")
            elif tag in self.block_tags:
                self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style", "noscript"} and self.skip_depth:
            self.skip_depth -= 1
        elif self.skip_depth == 0 and tag in self.block_tags:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if self.skip_depth == 0:
            self.parts.append(data)

    def text(self) -> str:
        raw = html.unescape("".join(self.parts)).replace("\xa0", " ")
        lines: list[str] = []
        for value in raw.splitlines():
            line = re.sub(r"[ \t]+", " ", value).strip()
            if not line:
                if lines and lines[-1] != "":
                    lines.append("")
                continue
            lowered = line.casefold()
            if lowered in {
                "site officiel", "en savoir plus…", "en savoir plus...",
                "télécharger", "telecharger",
            }:
                continue
            lines.append(line)
        return "\n".join(lines).strip()


class ArticleMetaParser(HTMLParser):
    def __init__(self, base_url: str) -> None:
        super().__init__(convert_charrefs=True)
        self.base_url = base_url
        self.image_url = ""
        self.official_url = ""

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = {key.casefold(): value or "" for key, value in attrs}
        if tag == "meta" and values.get("property", "").casefold() == "og:image":
            self.image_url = urljoin(self.base_url, values.get("content", ""))
        if tag == "a":
            classes = values.get("class", "").casefold().split()
            if "site_officiel" in classes or "site-officiel" in classes:
                self.official_url = urljoin(self.base_url, values.get("href", ""))


def extract_text(raw_html: str) -> str:
    parser = TextExtractor()
    parser.feed(raw_html)
    return parser.text()


def parse_category(title: str, content: str) -> tuple[str, str, str]:
    match = re.match(r"^\s*\[([^]]+)]\s*(.+?)\s*$", title)
    label = match.group(1) if match else ""
    clean_title = match.group(2) if match else title.strip()
    haystack = f"{label} {clean_title} {content[:500]}".casefold()
    for needle, key, chinese in CATEGORY_RULES:
        if needle in haystack:
            return key, chinese, clean_title
    return "other", "其他", clean_title


def infer_kind(category: str, title: str, content: str) -> str:
    haystack = f"{title} {content[:600]}".casefold()
    if category == "driver" or any(x in haystack for x in ("turnip", "adreno driver", "mesa driver")):
        return "driver"
    if category == "tools" or any(x in haystack for x in ("frontend", "launcher", "outil", "utility")):
        return "tool"
    return "emulator"


def infer_platforms(title: str, content: str) -> list[str]:
    haystack = f"{title} {content[:2000]}".casefold()
    platforms: list[str] = []
    if "android" in haystack or "apk" in haystack:
        platforms.append("android")
    if any(x in haystack for x in ("windows", "linux", "macos", "mac os", "appimage")):
        platforms.append("pc")
    return platforms


def normalized(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.casefold())


def load_emulator_names() -> list[tuple[str, str]]:
    config = json.loads((ROOT / "assets" / "emulators.json").read_text(encoding="utf-8"))
    values: list[tuple[str, str]] = []
    for console in config.get("consoles", []):
        for emulator in console.get("emulators", []):
            name = re.sub(r"\s*\([^)]*\)\s*$", "", str(emulator.get("name", ""))).strip()
            token = normalized(name)
            if len(token) >= 4:
                values.append((str(emulator.get("id", "")), token))
    return values


def load_android_emulators() -> dict[str, dict[str, str]]:
    """Return unique Android emulator metadata used for generated news."""
    config = json.loads((ROOT / "assets" / "emulators.json").read_text(encoding="utf-8"))
    values: dict[str, dict[str, str]] = {}
    excluded_consoles = {"gpu_drivers", "emulation_tools"}
    for console in config.get("consoles", []):
        console_id = str(console.get("id", ""))
        if console_id in excluded_consoles:
            continue
        for emulator in console.get("emulators", []):
            emulator_id = str(emulator.get("id", ""))
            platforms = [str(value) for value in emulator.get("platforms", [])]
            if (
                not emulator_id
                or emulator_id.endswith("_pc")
                or "android" not in platforms
            ):
                continue
            values.setdefault(
                emulator_id,
                {
                    "id": emulator_id,
                    "name": str(emulator.get("name", emulator_id)),
                    "iconPath": str(emulator.get("iconPath", "")),
                    "officialUrl": str(
                        emulator.get("sourceUrl") or emulator.get("website") or ""
                    ),
                },
            )
    return values


def parse_iso_datetime(value: Any) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    except (TypeError, ValueError):
        return None


def build_android_release_articles(
    existing_articles: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Turn recent catalog releases into fully translated Android news."""
    catalog_path = ROOT / "data" / "version_catalog.json"
    if not catalog_path.exists():
        catalog_path = ROOT / "assets" / "version_catalog.json"
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    entries = catalog.get("entries", {})
    emulators = load_android_emulators()
    cutoff = datetime.now(timezone.utc) - timedelta(days=RETENTION_DAYS)
    previous_generated = {
        str(article.get("id")): article
        for article in existing_articles
        if str(article.get("id", "")).startswith(ANDROID_NEWS_PREFIX)
    }

    # An Emu-France Android article published within three days of the tracked
    # release already covers the same event and should win over generated news.
    covered: dict[str, list[datetime]] = {}
    for article in existing_articles:
        if str(article.get("id", "")).startswith(ANDROID_NEWS_PREFIX):
            continue
        if "android" not in article.get("platforms", []):
            continue
        published = parse_iso_datetime(article.get("publishedAt"))
        if published is None:
            continue
        for emulator_id in article.get("relatedEmulatorIds", []):
            covered.setdefault(str(emulator_id), []).append(published)

    candidates: list[tuple[datetime, dict[str, Any]]] = []
    by_release: dict[tuple[str, str, str], dict[str, Any]] = {}
    for emulator_id, emulator in emulators.items():
        entry = entries.get(emulator_id)
        if not isinstance(entry, dict):
            continue
        version = str(entry.get("version", "")).strip()
        version_key = version.casefold()
        published = parse_iso_datetime(entry.get("releaseDate"))
        source_url = str(entry.get("sourceUrl", "")).strip()
        if (
            not version
            or any(
                marker in version_key
                for marker in ("linux", "windows", "macos", "appimage")
            )
            or published is None
            or published < cutoff
            or not source_url
        ):
            continue
        if any(
            abs((published - source_date).total_seconds()) <= 3 * 24 * 60 * 60
            for source_date in covered.get(emulator_id, [])
        ):
            continue

        # Several catalog IDs can point to the exact same upstream release.
        # Merge them before translating so one changelog is translated once.
        release_key = (source_url, version, published.isoformat())
        duplicate = by_release.get(release_key)
        if duplicate is not None:
            duplicate["relatedEmulatorIds"].append(emulator_id)
            continue

        candidate = {
            "emulatorId": emulator_id,
            "emulator": emulator,
            "version": version,
            "published": published,
            "sourceUrl": source_url,
            "releaseNotes": str(entry.get("releaseNotes", "")).strip(),
            "relatedEmulatorIds": [emulator_id],
        }
        by_release[release_key] = candidate
        candidates.append((published, candidate))

    # Select the visible window before translation. Candidates just outside the
    # 30-item limit must not consume translation calls on every scheduled run.
    candidates.sort(key=lambda item: item[0], reverse=True)
    articles: list[dict[str, Any]] = []
    for _, candidate in candidates[:ANDROID_NEWS_LIMIT]:
        emulator_id = str(candidate["emulatorId"])
        emulator = candidate["emulator"]
        version = str(candidate["version"])
        published = candidate["published"]
        source_url = str(candidate["sourceUrl"])
        release_notes = str(candidate["releaseNotes"])
        name = str(emulator["name"])
        published_label = published.strftime("%Y年%m月%d日")
        intro = (
            f"{name} 已发布 Android 最新版本 {version}。\n\n"
            f"发布日期：{published_label}\n"
            "适用平台：Android\n\n"
            "可通过下方“查看原文”打开官方发布页面，版本号、兼容性和安装要求"
            "请以项目官方说明为准。"
        )
        original = release_notes or f"{name} {version} Android release."
        digest = hashlib.sha256(
            (
                f"translation-v{ANDROID_TRANSLATION_VERSION}\n"
                f"{emulator_id}\n{version}\n{published.isoformat()}\n"
                f"{release_notes}"
            ).encode("utf-8")
        ).hexdigest()
        safe_version = re.sub(r"[^a-zA-Z0-9]+", "-", version).strip("-")[:40]
        article_id = f"{ANDROID_NEWS_PREFIX}{emulator_id}-{safe_version or digest[:10]}"
        previous_article = previous_generated.get(article_id)
        previous_content = str((previous_article or {}).get("content", ""))
        if (
            previous_article
            and previous_article.get("contentHash") == digest
            and "官方更新说明（中文）：" in previous_content
        ):
            content = previous_content
        else:
            chinese_notes = (
                translate_release_notes(release_notes)
                if release_notes
                else "官方未提供详细更新说明。"
            )
            content = f"{intro}\n\n官方更新说明（中文）：\n\n{chinese_notes}"
        article = {
            "id": article_id,
            "title": f"【Android更新】{name} {version}",
            "originalTitle": f"{name} {version} Android release",
            "category": "android_update",
            "categoryLabel": "Android更新",
            "kind": "emulator",
            "publishedAt": published.isoformat().replace("+00:00", "Z"),
            "sourceName": "EmuHub 版本追踪",
            "sourceUrl": source_url,
            "imageUrl": (
                f"asset://{emulator['iconPath']}" if emulator["iconPath"] else ""
            ),
            "officialUrl": emulator["officialUrl"],
            "summary": (
                f"{name} 发布 Android 新版本 {version}，发布日期为"
                f"{published_label}。点击查看官方版本信息与更新说明。"
            ),
            "content": content,
            "originalContent": original,
            "platforms": ["android"],
            "relatedEmulatorIds": candidate["relatedEmulatorIds"],
            "contentHash": digest,
        }
        articles.append(article)

    return articles


def related_ids(title: str, emulator_names: list[tuple[str, str]]) -> list[str]:
    token = normalized(title)
    matches = [emulator_id for emulator_id, name in emulator_names if name in token]
    return list(dict.fromkeys(matches))[:8]


def chunk_text(value: str, limit: int = 1200) -> list[str]:
    chunks: list[str] = []
    current = ""
    for paragraph in value.split("\n"):
        addition = paragraph if not current else f"\n{paragraph}"
        if len(current) + len(addition) <= limit:
            current += addition
            continue
        if current:
            chunks.append(current)
            current = ""
        while len(paragraph) > limit:
            cut = max(paragraph.rfind(". ", 0, limit), paragraph.rfind("; ", 0, limit))
            if cut < limit // 2:
                cut = limit
            chunks.append(paragraph[:cut].strip())
            paragraph = paragraph[cut:].strip()
        current = paragraph
    if current:
        chunks.append(current)
    return chunks


def translate_chunk(value: str) -> str:
    params = urlencode(
        {
            "client": "gtx",
            "sl": "auto",
            "tl": "zh-CN",
            "dt": "t",
            "q": value,
        }
    )
    url = f"https://translate.googleapis.com/translate_a/single?{params}"
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            data = json.loads(fetch(url, timeout=25).decode("utf-8"))
            translated = "".join(part[0] for part in data[0] if part and part[0])
            if translated.strip():
                return translated.strip()
        except Exception as error:  # pragma: no cover - network retry path
            last_error = error
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"translation failed: {last_error}")


def translate(value: str) -> str:
    translated: list[str] = []
    for chunk in chunk_text(value):
        translated.append(translate_chunk(chunk))
        time.sleep(0.12)
    return "\n".join(translated).strip()


def translate_release_notes(value: str) -> str:
    """Translate prose while preserving Markdown and technical identifiers."""
    protected: list[tuple[str, str]] = []

    def stash(raw: str) -> str:
        token = f"ZZEMUHUBTOKEN{len(protected):05d}ZZ"
        protected.append((token, raw))
        return token

    # Preserve fence delimiters and identifier-only lines inside code blocks.
    # Commit lines still contain spaces, so their human-readable messages are
    # translated while hashes and other tokens below remain untouched.
    lines: list[str] = []
    inside_fence = False
    for line in value.splitlines(keepends=True):
        body = line.rstrip("\r\n")
        ending = line[len(body):]
        stripped = body.strip()
        if stripped.startswith("```"):
            lines.append(stash(body) + ending)
            inside_fence = not inside_fence
        elif inside_fence and stripped and re.fullmatch(r"\S+", stripped):
            prefix = body[: len(body) - len(body.lstrip())]
            suffix = body[len(body.rstrip()):]
            lines.append(prefix + stash(stripped) + suffix + ending)
        else:
            lines.append(line)
    shielded = "".join(lines)

    patterns = (
        r"`[^`\r\n]+`",
        r"https?://[^\s)>\]]+",
        r"(?m)(?<=  )\S+$",
        r"(?<![\w/])[\w@+.-]+(?:/[\w@+.-]+)*\.[A-Za-z0-9][\w.-]*(?!\w)",
        r"\b[0-9a-fA-F]{7,64}\b",
        r"(?m)^[|:\- ]{3,}$",
    )
    for pattern in patterns:
        shielded = re.sub(pattern, lambda match: stash(match.group(0)), shielded)

    translated = translate(shielded)
    for token, raw in protected:
        if token not in translated:
            raise RuntimeError(f"translation damaged protected token: {token}")
        translated = translated.replace(token, raw)
    return translated.strip()


def summary_for(content: str, limit: int = 220) -> str:
    compact = re.sub(r"\s+", " ", content).strip()
    if len(compact) <= limit:
        return compact
    snippet = compact[:limit]
    cut = max(snippet.rfind("。"), snippet.rfind("！"), snippet.rfind("；"))
    if cut >= limit // 2:
        return snippet[: cut + 1]
    return snippet.rstrip("，,。.;； ") + "…"


def iso_date(raw: str) -> str:
    value = parsedate_to_datetime(raw)
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def load_previous() -> dict[str, dict[str, Any]]:
    for path in (ASSET_PATH, DATA_PATH):
        if not path.exists():
            continue
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            return {
                str(item["id"]): item
                for item in payload.get("articles", [])
                if isinstance(item, dict) and item.get("id")
            }
        except (OSError, ValueError, TypeError):
            continue
    return {}


def load_existing_payload() -> dict[str, Any]:
    for path in (ASSET_PATH, DATA_PATH):
        if path.exists():
            try:
                value = json.loads(path.read_text(encoding="utf-8"))
                if isinstance(value, dict):
                    return value
            except (OSError, ValueError):
                pass
    return {}


def parse_feed() -> list[dict[str, str]]:
    root = ET.fromstring(fetch(FEED_URL))
    items: list[dict[str, str]] = []
    for item in root.findall("./channel/item"):
        def text_of(tag: str) -> str:
            return (item.findtext(tag) or "").strip()

        link = text_of("link")
        title = html.unescape(text_of("title"))
        match = re.search(r"/news/(\d+)-", link)
        article_id = match.group(1) if match else hashlib.sha1(link.encode()).hexdigest()[:12]
        content = extract_text(text_of("description"))
        if link and title and content:
            items.append(
                {
                    "id": article_id,
                    "link": link,
                    "title": title,
                    "content": content,
                    "publishedAt": iso_date(text_of("pubDate")),
                }
            )
    return items


def build_article(
    raw: dict[str, str],
    previous: dict[str, Any] | None,
    emulator_names: list[tuple[str, str]],
) -> dict[str, Any]:
    original_title = raw["title"]
    original_content = raw["content"]
    category, category_label, clean_title = parse_category(original_title, original_content)
    digest = hashlib.sha256(
        f"{original_title}\n{original_content}".encode("utf-8")
    ).hexdigest()

    if previous and previous.get("contentHash") == digest and previous.get("content"):
        chinese_content = str(previous["content"])
    else:
        chinese_content = translate(original_content)

    image_url = str((previous or {}).get("imageUrl", ""))
    official_url = str((previous or {}).get("officialUrl", ""))
    # An article's cover and official URL are effectively immutable. Reusing
    # the previous values makes routine two-hour refreshes finish in seconds.
    if previous is None:
        try:
            parser = ArticleMetaParser(raw["link"])
            parser.feed(fetch(raw["link"], timeout=20).decode("utf-8", errors="replace"))
            image_url = parser.image_url or image_url
            official_url = parser.official_url or official_url
        except Exception as error:  # metadata is useful but not required
            print(f"warning: metadata fetch failed for {raw['link']}: {error}", file=sys.stderr)

    return {
        "id": raw["id"],
        "title": f"【{category_label}】{clean_title}",
        "originalTitle": original_title,
        "category": category,
        "categoryLabel": category_label,
        "kind": infer_kind(category, clean_title, original_content),
        "publishedAt": raw["publishedAt"],
        "sourceName": "Emu-France",
        "sourceUrl": raw["link"],
        "imageUrl": image_url,
        "officialUrl": official_url,
        "summary": summary_for(chinese_content),
        "content": chinese_content,
        "originalContent": original_content,
        "platforms": infer_platforms(clean_title, original_content),
        "relatedEmulatorIds": related_ids(clean_title, emulator_names),
        "contentHash": digest,
    }


def write_payload(payload: dict[str, Any]) -> None:
    rendered = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    ASSET_PATH.write_text(rendered, encoding="utf-8")
    DATA_PATH.parent.mkdir(parents=True, exist_ok=True)
    DATA_PATH.write_text(rendered, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="process only the first N RSS items (for local smoke tests)",
    )
    parser.add_argument(
        "--catalog-only",
        action="store_true",
        help="keep existing RSS articles and only refresh generated Android news",
    )
    args = parser.parse_args()

    existing_payload = load_existing_payload()
    previous = load_previous()
    emulator_names = load_emulator_names()
    incoming = [] if args.catalog_only else parse_feed()
    if args.limit > 0:
        incoming = incoming[: args.limit]

    merged = dict(previous)
    updated = 0
    for index, raw in enumerate(incoming, start=1):
        old = previous.get(raw["id"])
        try:
            merged[raw["id"]] = build_article(raw, old, emulator_names)
            updated += 1
            print(f"[{index}/{len(incoming)}] {raw['title']}")
        except Exception as error:
            if old:
                print(f"warning: retained old translation for {raw['id']}: {error}", file=sys.stderr)
            else:
                print(f"warning: skipped {raw['id']}: {error}", file=sys.stderr)

    # Build before removing old generated entries so unchanged translations can
    # be reused. Superseded versions are still removed on every run.
    generated_android = build_android_release_articles(list(merged.values()))
    merged = {
        key: value
        for key, value in merged.items()
        if not str(key).startswith(ANDROID_NEWS_PREFIX)
    }
    for article in generated_android:
        merged[str(article["id"])] = article

    cutoff = datetime.now(timezone.utc) - timedelta(days=RETENTION_DAYS)
    articles = []
    for article in merged.values():
        try:
            published = datetime.fromisoformat(str(article["publishedAt"]).replace("Z", "+00:00"))
        except (KeyError, TypeError, ValueError):
            continue
        if published >= cutoff and article.get("content"):
            articles.append(article)
    articles.sort(key=lambda value: str(value["publishedAt"]), reverse=True)

    if not articles:
        raise RuntimeError("refusing to write an empty news feed")

    payload = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "retentionDays": RETENTION_DAYS,
        "source": {
            "name": "Emu-France",
            "url": SOURCE_URL,
            "feedUrl": FEED_URL,
        },
        "articles": articles,
    }
    existing_comparable = dict(existing_payload)
    candidate_comparable = dict(payload)
    existing_comparable.pop("generatedAt", None)
    candidate_comparable.pop("generatedAt", None)
    if existing_comparable == candidate_comparable and existing_payload.get("generatedAt"):
        payload["generatedAt"] = existing_payload["generatedAt"]
    write_payload(payload)
    print(
        f"wrote {len(articles)} articles "
        f"({updated} RSS refreshed, {len(generated_android)} Android releases)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
