#!/usr/bin/env python3
"""Build the lightweight version catalog consumed by the mobile app.

GitHub's public Releases HTML pages are large and expensive to download on a
phone.  This script runs in GitHub Actions, where the repository token can use
the Releases API, and reduces all GitHub release data to one small JSON file.
Entries are selected by the greatest ``published_at`` value, not by GitHub's
mutable "Latest" flag or by semantic-version ordering.
"""

from __future__ import annotations

import concurrent.futures
import datetime as dt
import json
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "assets" / "emulators.json"
OUTPUT_PATHS = (
    ROOT / "assets" / "version_catalog.json",
    ROOT / "data" / "version_catalog.json",
)
API_ROOT = "https://api.github.com"
MAX_RELEASE_PAGES = 10
ROLLING_TAGS = {
    "nightly",
    "continuous",
    "latest",
    "canary",
    "dev",
    "development",
    "preview",
}


def github_repo(raw_url: str) -> tuple[str, str] | None:
    try:
        parsed = urllib.parse.urlparse(raw_url)
    except ValueError:
        return None
    if parsed.scheme not in {"http", "https"} or parsed.netloc.lower() != "github.com":
        return None
    parts = [urllib.parse.unquote(part) for part in parsed.path.split("/") if part]
    if len(parts) < 2:
        return None
    owner, repo = parts[0], parts[1]
    if repo.endswith(".git"):
        repo = repo[:-4]
    return owner, repo


def api_json(url: str, token: str, attempts: int = 3):
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "EmuHub-Version-Catalog",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    for attempt in range(attempts):
        request = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
            if isinstance(error, urllib.error.HTTPError) and error.code == 404:
                return None
            if attempt + 1 == attempts:
                raise
            time.sleep(1.5 * (attempt + 1))
    return None


def fetch_releases(repo: tuple[str, str], token: str) -> list[dict]:
    owner, name = repo
    releases: list[dict] = []
    for page in range(1, MAX_RELEASE_PAGES + 1):
        encoded_owner = urllib.parse.quote(owner, safe="")
        encoded_name = urllib.parse.quote(name, safe="")
        url = (
            f"{API_ROOT}/repos/{encoded_owner}/{encoded_name}/releases"
            f"?per_page=100&page={page}"
        )
        payload = api_json(url, token)
        if not isinstance(payload, list):
            break
        releases.extend(item for item in payload if isinstance(item, dict))
        if len(payload) < 100:
            break
    return releases


def parse_time(value: object) -> dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def display_version(release: dict) -> str:
    tag = urllib.parse.unquote(str(release.get("tag_name") or "").strip())
    if tag[:1].lower() == "v":
        tag = tag[1:]
    normalized = tag.lower()
    if normalized not in ROLLING_TAGS:
        return tag

    title = str(release.get("name") or "")
    match = re.search(r"\b(20\d{2}(?:[._-]\d{2}[._-]\d{2}|[._-]\d{4}|\d{4}))\b", title)
    return f"{normalized}-{match.group(1)}" if match else tag


def apk_priority(name: str) -> int:
    value = name.lower()
    score = 0
    if any(part in value for part in ("arm64", "aarch64", "arm64-v8a")):
        score += 100
    if any(part in value for part in ("standard", "vanilla", "universal")):
        score += 60
    if any(part in value for part in ("ludashi", "pubg", "antutu", "benchmark")):
        score -= 80
    if "debug" in value:
        score -= 120
    return score


def best_apk(release: dict) -> str | None:
    candidates: list[tuple[int, str]] = []
    for asset in release.get("assets") or []:
        if not isinstance(asset, dict):
            continue
        url = str(asset.get("browser_download_url") or "")
        if not url.lower().endswith(".apk"):
            continue
        name = str(asset.get("name") or url)
        candidates.append((apk_priority(name), url))
    return max(candidates, default=(0, None), key=lambda item: item[0])[1]


def newest_release(releases: list[dict]) -> dict | None:
    candidates = [
        release
        for release in releases
        if not release.get("draft") and parse_time(release.get("published_at")) is not None
    ]
    if not candidates:
        return None
    return max(candidates, key=lambda release: parse_time(release.get("published_at")))


def catalog_entry(release: dict) -> dict:
    notes = str(release.get("body") or "").strip()
    # Keep the shared catalog small enough for mobile networks. The detail page
    # can still open the source release for unusually long changelogs.
    if len(notes) > 4000:
        notes = notes[:3999].rstrip() + "…"
    result = {
        "version": display_version(release),
        "releaseDate": release.get("published_at"),
        "sourceUrl": release.get("html_url"),
    }
    if notes:
        result["releaseNotes"] = notes
    apk = best_apk(release)
    if apk:
        result["downloadUrl"] = apk
    if release.get("prerelease"):
        if apk:
            result["devDownloadUrl"] = apk
        if notes:
            result["devReleaseNotes"] = notes
    return result


def load_previous() -> dict:
    for path in OUTPUT_PATHS:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(value, dict):
                return value
        except (OSError, json.JSONDecodeError):
            pass
    return {"entries": {}}


def main() -> int:
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    emulators = [
        emulator
        for console in config.get("consoles", [])
        for emulator in console.get("emulators", [])
    ]
    github_emulators = [
        emulator for emulator in emulators if emulator.get("sourceType") == "github"
    ]

    repos: set[tuple[str, str]] = set()
    emulator_repos: dict[str, list[tuple[str, str]]] = {}
    for emulator in github_emulators:
        item_repos: list[tuple[str, str]] = []
        for field in ("sourceUrl", "devUrl", "nightlyUrl"):
            repo = github_repo(str(emulator.get(field) or ""))
            if repo is not None and repo not in item_repos:
                item_repos.append(repo)
                repos.add(repo)
        emulator_repos[str(emulator["id"])] = item_repos

    releases_by_repo: dict[tuple[str, str], list[dict]] = {}
    failures: list[str] = []
    workers = min(12, max(1, len(repos)))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(fetch_releases, repo, token): repo for repo in repos}
        for future in concurrent.futures.as_completed(futures):
            repo = futures[future]
            try:
                releases_by_repo[repo] = future.result()
            except Exception as error:  # noqa: BLE001 - retain previous catalog on any request failure
                failures.append(f"{repo[0]}/{repo[1]}: {error}")

    previous_entries = load_previous().get("entries") or {}
    entries: dict[str, dict] = {}
    for emulator in github_emulators:
        emulator_id = str(emulator["id"])
        candidates = [
            release
            for repo in emulator_repos.get(emulator_id, [])
            for release in releases_by_repo.get(repo, [])
        ]
        selected = newest_release(candidates)
        if selected is not None:
            entries[emulator_id] = catalog_entry(selected)
        elif emulator_id in previous_entries:
            # A temporary API failure must never erase a previously confirmed
            # version from the catalog.
            entries[emulator_id] = previous_entries[emulator_id]

    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    catalog = {
        "schemaVersion": 1,
        "generatedAt": now.isoformat().replace("+00:00", "Z"),
        "selection": "greatest published_at across configured GitHub release channels",
        "entries": dict(sorted(entries.items())),
    }
    rendered = json.dumps(catalog, ensure_ascii=False, indent=2) + "\n"
    for path in OUTPUT_PATHS:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rendered, encoding="utf-8")

    print(
        f"catalog entries={len(entries)} github_emulators={len(github_emulators)} "
        f"repositories={len(repos)} failures={len(failures)}"
    )
    for failure in failures:
        print(f"warning: {failure}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
