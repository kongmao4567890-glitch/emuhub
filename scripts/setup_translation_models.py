#!/usr/bin/env python3
"""Download and verify the small offline models used by the news workflow."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import tempfile
from urllib.request import Request, urlopen
import zipfile


USER_AGENT = (
    "EmuHub-News/1.0 (+https://github.com/kongmao4567890-glitch/emuhub)"
)
MODEL_SPECS = (
    {
        "directory": "translate-fr_en-1_9",
        "url": "https://argos-net.com/v1/translate-fr_en-1_9.argosmodel",
        "sha256": "3b3052fee6bb1e8e8e632a26a723eb2a2c7710dfe73ba61ffd9b83e85d4f14c1",
    },
    {
        "directory": "translate-en_zh-1_9",
        "url": "https://argos-net.com/v1/translate-en_zh-1_9.argosmodel",
        "sha256": "433e7c4f034d87fbe2353161e05f18646d7999452f801a4e1f0378522b9850ab",
    },
)


def model_root() -> Path:
    configured = os.environ.get("EMUHUB_TRANSLATION_MODELS", "").strip()
    if configured:
        return Path(configured).expanduser()
    return Path.home() / ".cache" / "emuhub-translation" / "models"


def model_ready(path: Path) -> bool:
    return (path / "model" / "model.bin").is_file() and (
        path / "sentencepiece.model"
    ).is_file()


def download(url: str, destination: Path) -> str:
    digest = hashlib.sha256()
    request = Request(url, headers={"User-Agent": USER_AGENT})
    with (
        urlopen(request, timeout=120) as response,
        destination.open("wb") as output,
    ):
        while chunk := response.read(1024 * 1024):
            output.write(chunk)
            digest.update(chunk)
    return digest.hexdigest()


def safe_extract(archive: Path, destination: Path, directory: str) -> None:
    with zipfile.ZipFile(archive) as bundle:
        for member in bundle.infolist():
            path = PurePosixPath(member.filename)
            if path.is_absolute() or ".." in path.parts or not path.parts:
                raise RuntimeError(f"unsafe model archive member: {member.filename}")
            if path.parts[0] != directory:
                raise RuntimeError(
                    f"unexpected model archive member: {member.filename}"
                )
        bundle.extractall(destination)


def install_model(spec: dict[str, str], root: Path) -> None:
    directory = spec["directory"]
    target = root / directory
    if model_ready(target):
        print(f"model ready: {directory}")
        return

    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="emuhub-model-", dir=root) as temp_name:
        temp = Path(temp_name)
        archive = temp / f"{directory}.argosmodel"
        actual = download(spec["url"], archive)
        if actual != spec["sha256"]:
            raise RuntimeError(
                f"checksum mismatch for {directory}: "
                f"expected {spec['sha256']}, got {actual}"
            )
        safe_extract(archive, temp, directory)
        extracted = temp / directory
        if not model_ready(extracted):
            raise RuntimeError(f"incomplete model archive: {directory}")
        if target.exists():
            shutil.rmtree(target)
        shutil.move(str(extracted), str(target))
    print(f"model installed: {directory}")


def main() -> int:
    root = model_root()
    for spec in MODEL_SPECS:
        install_model(spec, root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
