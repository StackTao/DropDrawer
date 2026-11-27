#!/usr/bin/env python3
"""Synchronize a verified, bounded static mirror of DropDrawer release assets."""

import argparse
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
from urllib.parse import quote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

RELEASES = "https://api.github.com/repos/StackTao/DropDrawer/releases?per_page=20"
DOWNLOADS = "https://github.com/StackTao/DropDrawer/releases/download"
ASSET_NAMES = frozenset({
    "DropDrawer-macOS-arm64.dmg",
    "DropDrawer-macOS.dmg",
    "DropDrawer-Windows-x64-Setup.exe",
    "DropDrawer-Android-arm64.apk",
    "DropDrawer-Android-universal.apk",
    "DropDrawer-iOS-native-arm64-unsigned.ipa",
    "SHA256SUMS.txt",
})
TAG = re.compile(r"v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?", re.ASCII)
DIGEST = re.compile(r"sha256:([a-f0-9]{64})")
MAX_FILE_BYTES = 256 * 1024**2
MAX_CACHE_BYTES = 768 * 1024**2
MAX_FEED_BYTES = 2 * 1024**2
CHUNK_BYTES = 1024**2


@dataclass(frozen=True)
class Asset:
    tag: str
    name: str
    size: int
    digest: str

    @property
    def path(self):
        return Path(self.tag) / self.name


class ReleaseRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        url = urlsplit(newurl)
        if (url.scheme != "https" or url.username is not None
                or url.port not in (None, 443) or url.hostname not in {
                    "github.com", "release-assets.githubusercontent.com",
                    "objects.githubusercontent.com",
                }):
            raise ValueError("Unexpected release asset redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


OPENER = build_opener(ReleaseRedirects())


def fetch(url, accept):
    request = Request(url, headers={"User-Agent": "DropDrawer-UpdateMirror", "Accept": accept})
    return OPENER.open(request, timeout=45)


def select_assets(releases):
    assets = {}
    tags = set()
    size = 0
    for release in releases:
        tag = release.get("tag_name", "")
        if release.get("draft") or len(tag) > 64 or not TAG.fullmatch(tag):
            continue
        for row in release.get("assets", []):
            name = row.get("name")
            length = row.get("size")
            digest = DIGEST.fullmatch(row.get("digest") or "")
            if (name not in ASSET_NAMES or not isinstance(length, int)
                    or not 0 < length <= MAX_FILE_BYTES or not digest
                    or size + length > MAX_CACHE_BYTES):
                continue
            asset = Asset(tag, name, length, digest[1])
            if asset.path not in assets:
                tags.add(tag)
                assets[asset.path] = asset
                size += length
        if len(tags) >= 2:
            break
    if not assets:
        raise ValueError("No verified release assets in GitHub response")
    return assets


def has_expected_bytes(path, asset):
    if not path.is_file() or path.stat().st_size != asset.size:
        return False
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(CHUNK_BYTES):
            digest.update(chunk)
    return digest.hexdigest() == asset.digest


def download(asset, path):
    url = f"{DOWNLOADS}/{quote(asset.tag, safe='')}/{quote(asset.name, safe='')}"
    digest = hashlib.sha256()
    received = 0
    with fetch(url, "application/octet-stream") as response, path.open("wb") as file:
        while chunk := response.read(CHUNK_BYTES):
            received += len(chunk)
            if received > asset.size:
                raise ValueError(f"Release asset exceeds GitHub size: {asset.path}")
            digest.update(chunk)
            file.write(chunk)
    if received != asset.size or digest.hexdigest() != asset.digest:
        raise ValueError(f"Release asset verification failed: {asset.path}")


def synchronize(root, assets):
    current = root / "current"
    reusable = {
        path for path, asset in assets.items()
        if has_expected_bytes(current / path, asset)
    }
    if reusable == set(assets) and {
        path.relative_to(current) for path in current.glob("*/*") if path.is_file()
    } == reusable:
        return

    snapshot = Path(tempfile.mkdtemp(prefix=".snapshot-", dir=root))
    next_link = root / ".current-next"
    try:
        snapshot.chmod(0o755)
        for relative, asset in assets.items():
            destination = snapshot / relative
            destination.parent.mkdir(mode=0o755, exist_ok=True)
            if relative in reusable:
                os.link(current / relative, destination)
            else:
                download(asset, destination)
                destination.chmod(0o644)
        next_link.unlink(missing_ok=True)
        next_link.symlink_to(snapshot.name, target_is_directory=True)
        next_link.replace(current)
    except Exception:
        next_link.unlink(missing_ok=True)
        shutil.rmtree(snapshot)
        raise

    for old in root.glob(".snapshot-*"):
        if old != snapshot and old.is_dir() and not old.is_symlink():
            shutil.rmtree(old)
    print(f"Mirrored {len(assets)} assets for {', '.join(sorted({a.tag for a in assets.values()}))}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cache_dir", type=Path)
    args = parser.parse_args()
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    with (args.cache_dir / ".sync.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        with fetch(RELEASES, "application/vnd.github+json") as response:
            raw = response.read(MAX_FEED_BYTES + 1)
        if len(raw) > MAX_FEED_BYTES:
            raise ValueError("GitHub releases response exceeds size limit")
        synchronize(args.cache_dir, select_assets(json.loads(raw)))


if __name__ == "__main__":
    main()
