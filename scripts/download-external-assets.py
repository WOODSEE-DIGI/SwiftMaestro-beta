#!/usr/bin/env python3
"""
Download external image/PDF assets and YouTube thumbnails referenced in a
Notes.md / Markdown vault so Notes.md can display them offline.

Downloads are placed in the per-vault `_ASSETS` folder that matches each note's
top-level vault (e.g. `WDS_Tech_Resources/_ASSETS`, `My Story Public/_ASSETS`).
YouTube watch URLs become local thumbnail images that link to the video.

Usage:
    python3 scripts/download-external-assets.py \
        --vault "/Users/<you>/Library/Mobile Documents/com~apple~CloudDocs/SwiftMaestro Notes" \
        --workers 10
"""

import argparse
import hashlib
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".heic", ".tif", ".tiff"}
PDF_EXTENSIONS = {".pdf"}
DOWNLOAD_EXTENSIONS = IMAGE_EXTENSIONS | PDF_EXTENSIONS
YOUTUBE_DOMAINS = {"youtube.com", "www.youtube.com", "youtu.be"}


def should_skip_dir(parts):
    return any(p.startswith(".") or p == "node_modules" for p in parts)


def vault_root(note_path: Path, vault: Path) -> Path:
    rel = note_path.resolve().relative_to(vault.resolve())
    parts = rel.parts
    if len(parts) <= 1:
        return vault
    return vault / parts[0]


def asset_folder(root: Path) -> Path:
    for name in ("_ASSETS", "_Assets", "_assets"):
        folder = root / name
        if folder.is_dir():
            return folder
    return root / "_ASSETS"


def youtube_video_id(url: str) -> str | None:
    try:
        p = urllib.parse.urlparse(url)
    except Exception:
        return None
    if p.netloc == "youtu.be":
        return p.path.strip("/").split("/")[0]
    if "youtube.com" in p.netloc:
        q = urllib.parse.parse_qs(p.query)
        if "v" in q:
            return q["v"][0]
    return None


def safe_filename(url: str, content_type: str | None) -> str:
    p = urllib.parse.urlparse(url)
    base = Path(p.path).name or "asset"
    base = re.sub(r"[^\w\s.-]", "_", base).strip("._")
    if not base:
        base = "asset"
    ext = Path(base).suffix.lower()
    if not ext or ext not in DOWNLOAD_EXTENSIONS:
        guessed = mimetypes.guess_extension(content_type or "") if content_type else None
        if guessed:
            ext = guessed.lower()
        else:
            ext = ".jpg"
        base = Path(base).stem + ext
    h = hashlib.sha256(url.encode("utf-8")).hexdigest()[:8]
    stem = Path(base).stem[:80]
    return f"{stem}_{h}{ext}"


def download_file(url: str, dest: Path, headers: dict) -> bool:
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read()
            if not data:
                return False
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
        return True
    except Exception:
        return False


def download_youtube_thumbnail(video_id: str, dest: Path, headers: dict) -> bool:
    for qual in ("maxresdefault", "sddefault", "hqdefault", "mqdefault", "default"):
        url = f"https://img.youtube.com/vi/{video_id}/{qual}.jpg"
        if download_file(url, dest, headers):
            return True
    return False


def run_clamscan(folder: Path) -> bool:
    clam = shutil.which("clamscan")
    if not clam:
        print("clamscan not found; skipping malware scan.", file=sys.stderr)
        return True
    print(f"Running clamscan on {folder} ...")
    result = subprocess.run([clam, "-r", "--infected", str(folder)], capture_output=True, text=True)
    print(result.stdout)
    if result.returncode == 0:
        print(f"clamscan: no infections found in {folder}.")
        return True
    if result.returncode == 1:
        print(f"clamscan: infections found in {folder}! Review output above.", file=sys.stderr)
        return False
    print(f"clamscan error (exit {result.returncode}):\n{result.stderr}", file=sys.stderr)
    return False


def make_relative(note_dir: Path, target: Path) -> str:
    rel = os.path.relpath(str(target.resolve()), str(note_dir.resolve()))
    return urllib.parse.quote(rel.replace("\\", "/"), safe="/")


class RootCache:
    def __init__(self, root: Path):
        self.root = root
        self.folder = asset_folder(root)
        self.lock = threading.Lock()
        self.cache: dict[str, str] = {}
        self.mapping_path = self.folder / "_mapping.json"
        self.load()

    def load(self):
        if self.mapping_path.exists():
            try:
                self.cache = json.loads(self.mapping_path.read_text(encoding="utf-8"))
            except Exception:
                self.cache = {}

    def save(self):
        self.mapping_path.write_text(json.dumps(self.cache, indent=2, sort_keys=True), encoding="utf-8")


def collect_references(vault: Path):
    notes = [p for p in vault.rglob("*.md") if not should_skip_dir(p.relative_to(vault).parts)]
    image_pattern = re.compile(r"!\[([^\]]*)\]\(([^)]+)\)")
    link_pattern = re.compile(r"(?<!!)\[([^\]]*)\]\(([^)]+)\)")

    file_groups: dict[tuple[str, Path], list[Path]] = {}
    yt_groups: dict[tuple[str, Path], list[Path]] = {}

    for note in notes:
        try:
            text = note.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        root = vault_root(note, vault)
        for m in image_pattern.finditer(text):
            url = m.group(2).strip()
            if url.startswith("data:") or not url.startswith("http"):
                continue
            vid = youtube_video_id(url)
            if vid:
                yt_groups.setdefault((url, root), []).append(note)
            else:
                file_groups.setdefault((url, root), []).append(note)
        for m in link_pattern.finditer(text):
            url = m.group(2).strip()
            if not url.startswith("http"):
                continue
            low = url.lower()
            if any(low.endswith(ext) for ext in DOWNLOAD_EXTENSIONS):
                file_groups.setdefault((url, root), []).append(note)

    return notes, file_groups, yt_groups


def download_regular(url: str, root: Path, cache: RootCache, headers: dict, counters: dict, counter_lock: threading.Lock) -> str | None:
    if url in cache.cache:
        with counter_lock:
            counters["skipped"] += 1
        return None

    filename = safe_filename(url, None)
    dest = cache.folder / filename
    result = download_file(url, dest, headers)

    if result:
        ct = mimetypes.guess_type(str(dest))[0]
        if ct:
            new_filename = safe_filename(url, ct)
            if new_filename != filename:
                new_dest = cache.folder / new_filename
                dest.rename(new_dest)
                filename = new_filename
                dest = new_dest
        with cache.lock:
            cache.cache[url] = filename
            cache.save()
        with counter_lock:
            counters["downloaded"] += 1
        return filename
    else:
        with counter_lock:
            counters["failed"] += 1
            counters["failed_urls"].append(url)
        return None


def download_youtube(url: str, root: Path, cache: RootCache, headers: dict, counters: dict, counter_lock: threading.Lock) -> str | None:
    if url in cache.cache:
        with counter_lock:
            counters["skipped"] += 1
        return None
    vid = youtube_video_id(url)
    if not vid:
        return None
    filename = f"yt_{vid}.jpg"
    dest = cache.folder / filename
    if download_youtube_thumbnail(vid, dest, headers):
        with cache.lock:
            cache.cache[url] = filename
            cache.save()
        with counter_lock:
            counters["downloaded"] += 1
        return filename
    else:
        with counter_lock:
            counters["failed"] += 1
            counters["failed_urls"].append(url)
        return None


def rewrite_notes(file_groups, yt_groups, root_caches):
    rewritten = 0
    # Group by note to write once
    notes_to_rewrite: dict[Path, str] = {}
    for (url, root), note_paths in {**file_groups, **yt_groups}.items():
        cache = root_caches.get(str(root))
        if not cache or url not in cache.cache:
            continue
        target = cache.folder / cache.cache[url]
        for note in note_paths:
            text = notes_to_rewrite.get(note)
            if text is None:
                try:
                    text = note.read_text(encoding="utf-8")
                except Exception:
                    continue
            rel = make_relative(note.parent, target)
            if (url, root) in yt_groups:
                text = re.sub(re.escape(f"![]({url})"), f"[![YouTube]({rel})]({url})", text)
                text = re.sub(re.escape(f"![YouTube]({url})"), f"[![YouTube]({rel})]({url})", text)
            else:
                text = text.replace(f"]({url})", f"]({rel})")
            notes_to_rewrite[note] = text

    for note, text in notes_to_rewrite.items():
        note.write_text(text, encoding="utf-8")
        rewritten += 1
    return rewritten


def main() -> int:
    parser = argparse.ArgumentParser(description="Download external vault assets for offline display")
    parser.add_argument("--vault", required=True, help="Path to the Notes.md vault")
    parser.add_argument("--dry-run", action="store_true", help="Preview URLs without downloading")
    parser.add_argument("--no-scan", action="store_true", help="Skip clamscan malware scan")
    parser.add_argument("--workers", type=int, default=10, help="Concurrent download workers")
    args = parser.parse_args()

    vault = Path(args.vault).expanduser().resolve()
    if not vault.is_dir():
        print(f"Vault not found: {vault}", file=sys.stderr)
        return 1

    headers = {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }

    print("Scanning notes for external references...")
    notes, file_groups, yt_groups = collect_references(vault)
    print(f"Found {len(file_groups)} external file URL/root groups and {len(yt_groups)} YouTube URL/root groups across {len(notes)} notes.")

    if args.dry_run:
        print("\nExternal files that would be downloaded (per vault root):")
        for (url, root), note_paths in sorted(file_groups.items())[:50]:
            print(f"  [{root.name}] {url[:120]}")
        if len(file_groups) > 50:
            print(f"  ... and {len(file_groups) - 50} more")
        print("\nYouTube videos that would get thumbnails (per vault root):")
        for (url, root), note_paths in sorted(yt_groups.items())[:20]:
            print(f"  [{root.name}] {url[:120]}")
        if len(yt_groups) > 20:
            print(f"  ... and {len(yt_groups) - 20} more")
        return 0

    # Prepare caches per root
    roots = {root for _, root in {**file_groups, **yt_groups}.keys()}
    root_caches: dict[str, RootCache] = {}
    for root in roots:
        cache = RootCache(root)
        cache.folder.mkdir(parents=True, exist_ok=True)
        root_caches[str(root)] = cache

    counters = {"downloaded": 0, "skipped": 0, "failed": 0, "failed_urls": []}
    counter_lock = threading.Lock()

    start = time.time()

    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        # Regular files
        futures = {
            executor.submit(download_regular, url, root, root_caches[str(root)], headers, counters, counter_lock): (url, root)
            for (url, root) in file_groups.keys()
        }
        total = len(file_groups)
        completed = 0
        for future in as_completed(futures):
            completed += 1
            url, root = futures[future]
            try:
                future.result()
            except Exception as e:
                with counter_lock:
                    counters["failed"] += 1
                    counters["failed_urls"].append(url)
                print(f"[{completed}/{total}] ERROR [{root.name}]: {url[:80]} - {e}")
            if completed % 100 == 0:
                elapsed = time.time() - start
                rate = completed / elapsed if elapsed else 0
                remaining = (total - completed) / rate if rate else 0
                print(f"Progress: {completed}/{total} ({rate:.1f}/s, ~{remaining/60:.1f}m remaining)")

        # YouTube thumbnails
        futures = {
            executor.submit(download_youtube, url, root, root_caches[str(root)], headers, counters, counter_lock): (url, root)
            for (url, root) in yt_groups.keys()
        }
        for future in as_completed(futures):
            try:
                future.result()
            except Exception as e:
                url, root = futures[future]
                print(f"[YT ERROR] [{root.name}]: {url[:80]} - {e}")

    print(f"\nDownload complete: {counters['downloaded']} new, {counters['skipped']} already cached, {counters['failed']} failed.")

    print("Rewriting note references...")
    rewritten = rewrite_notes(file_groups, yt_groups, root_caches)
    print(f"Rewrote {rewritten} note references to local assets.")

    # Malware scan
    if not args.no_scan:
        for root in roots:
            folder = root_caches[str(root)].folder
            if folder.exists():
                run_clamscan(folder)

    if counters["failed_urls"]:
        log = vault / "_download-failed.log"
        log.write_text("\n".join(counters["failed_urls"]), encoding="utf-8")
        print(f"\nFailed URLs logged to: {log}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
