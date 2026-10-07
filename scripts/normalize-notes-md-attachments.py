#!/usr/bin/env python3
"""
Normalize attachment references in a Notes.md / Markdown vault so Notes.md can
render images and open PDFs.

What it does:
- Converts Obsidian-style wikilink attachments `![[file.png]]` to standard
  Markdown links using relative paths.
- Images (.png/.jpg/.jpeg/.gif/.webp/.svg/.bmp) become `![alt](path)`.
- PDFs and other files become `[filename](path)`.
- Converts absolute / file:// paths that point inside the vault to relative paths.
- URL-encodes spaces and special characters in link targets.
- Reports missing attachments.

Usage:
    python3 scripts/normalize-notes-md-attachments.py \
        --vault "/Users/<you>/Library/Mobile Documents/com~apple~CloudDocs/SwiftMaestro Notes" \
        --dry-run

Omit --dry-run to write changes.
"""

import argparse
import re
import sys
import urllib.parse
from pathlib import Path

IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".heic", ".tif", ".tiff"}
PDF_EXTENSIONS = {".pdf"}
ATTACHMENT_EXTENSIONS = IMAGE_EXTENSIONS | PDF_EXTENSIONS | {".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".zip", ".mp4", ".mov", ".mp3", ".plist"}


def should_skip_dir(parts: list[str]) -> bool:
    return any(p.startswith(".") or p == "node_modules" for p in parts)


def looks_like_attachment(name: str) -> bool:
    """Return True if the reference looks like a file attachment rather than a note link."""
    name = name.strip().lstrip("./")
    if not name:
        return False
    if re.match(r"^(https?://|mailto:|#)", name, re.I):
        return False
    if "/" in name or "\\" in name:
        return True
    ext = Path(name).suffix.lower()
    return ext in ATTACHMENT_EXTENSIONS


def build_attachment_index(vault: Path) -> dict[str, list[Path]]:
    """Index every attachment file by basename for fast lookup."""
    index: dict[str, list[Path]] = {}
    for path in vault.rglob("*"):
        if not path.is_file():
            continue
        if should_skip_dir(path.relative_to(vault).parts):
            continue
        if path.suffix.lower() not in ATTACHMENT_EXTENSIONS:
            continue
        index.setdefault(path.name, []).append(path)
    return index


def vault_root(note_path: Path, vault: Path) -> Path:
    """Return the top-level vault folder containing the note (e.g. WDS_Tech_Resources)."""
    rel = note_path.resolve().relative_to(vault.resolve())
    parts = rel.parts
    if len(parts) <= 1:
        return vault
    return vault / parts[0]


def find_attachment(vault: Path, note_dir: Path, name: str, index: dict[str, list[Path]]) -> Path | None:
    """Search for an attachment relative to the note, common asset folders, or the vault index."""
    name = name.strip().lstrip("./")
    if not name:
        return None

    candidate = note_dir / name
    if candidate.exists() and candidate.is_file():
        return candidate

    root = vault_root(note_dir, vault)
    base = Path(name).name

    # Search per-vault and note-local asset folders recursively
    for sub in ("_assets", "_attachments", "assets", "attachments", "_ASSETS"):
        for folder in (note_dir / sub, root / sub, vault / sub):
            if folder.is_dir():
                for candidate in folder.rglob(base):
                    if candidate.is_file():
                        return candidate

    # Fast vault-wide lookup by basename
    matches = index.get(base, [])
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        # Prefer the match closest to the note directory
        note_str = str(note_dir.resolve())
        matches.sort(key=lambda p: len(str(p.resolve())) - len(note_str))
        return matches[0]

    return None


def make_relative(note_dir: Path, attachment: Path) -> str:
    import os
    rel = os.path.relpath(str(attachment.resolve()), str(note_dir.resolve()))
    # URL-encode spaces and special characters in link targets
    return urllib.parse.quote(rel.replace("\\", "/"), safe="/")


def convert_wikilinks(content: str, note_dir: Path, vault: Path, index: dict[str, list[Path]]) -> tuple[str, list[str]]:
    missing: list[str] = []

    def repl(match: re.Match) -> str:
        inner = match.group(1).strip()
        if "|" in inner:
            target, alias = inner.split("|", 1)
        else:
            target = inner
            alias = Path(target).stem

        ext = Path(target).suffix.lower()
        attachment = find_attachment(vault, note_dir, target, index)
        if not attachment:
            if looks_like_attachment(target):
                missing.append(target)
            return f"[{alias}]({target})"

        rel = make_relative(note_dir, attachment)
        if ext in IMAGE_EXTENSIONS:
            return f"![{alias}]({rel})"
        return f"[{alias}]({rel})"

    # Only convert embedded Obsidian wikilinks (![[file]]) for images/PDFs/attachments.
    # Plain [[note]] links are left untouched.
    content = re.sub(r"!\[\[([^\]]+)\]\]", repl, content)
    return content, missing


def normalize_standard_links(content: str, note_dir: Path, vault: Path, index: dict[str, list[Path]]) -> tuple[str, list[str]]:
    missing: list[str] = []

    def repl(match: re.Match) -> str:
        prefix = match.group(1)
        text = match.group(2)
        url = match.group(3).strip()

        if re.match(r"^(https?://|mailto:|#|data:)", url, re.I):
            return match.group(0)

        if url.startswith("file://"):
            url = urllib.parse.unquote(url[7:])

        url = urllib.parse.unquote(url)
        path = Path(url)
        if path.is_absolute() and path.exists():
            target = path
        else:
            target = note_dir / url
            if not target.exists():
                base = Path(url).name
                found = find_attachment(vault, note_dir, base, index)
                if found:
                    target = found
                else:
                    if looks_like_attachment(url):
                        missing.append(url)
                    return match.group(0)

        if not target.is_file():
            if looks_like_attachment(url):
                missing.append(url)
            return match.group(0)

        rel = make_relative(note_dir, target)
        return f"{prefix}[{text}]({rel})"

    pattern = re.compile(r"(!?)\[([^\]]*)\]\(([^)]+)\)")
    content = pattern.sub(repl, content)
    return content, missing


def main() -> int:
    parser = argparse.ArgumentParser(description="Normalize attachment links for Notes.md")
    parser.add_argument("--vault", required=True, help="Path to the Notes.md vault")
    parser.add_argument("--dry-run", action="store_true", help="Preview changes without writing")
    args = parser.parse_args()

    vault = Path(args.vault).expanduser().resolve()
    if not vault.is_dir():
        print(f"Vault not found: {vault}", file=sys.stderr)
        return 1

    print("Indexing attachments...")
    index = build_attachment_index(vault)
    print(f"Indexed {len(index)} attachment basenames.")

    notes = [p for p in vault.rglob("*.md") if not should_skip_dir(p.relative_to(vault).parts)]
    total_changed = 0
    all_missing: dict[str, list[str]] = {}

    for note in notes:
        try:
            text = note.read_text(encoding="utf-8")
        except Exception as e:
            print(f"Skipping {note}: {e}", file=sys.stderr)
            continue

        original = text
        text, missing_wiki = convert_wikilinks(text, note.parent, vault, index)
        text, missing_std = normalize_standard_links(text, note.parent, vault, index)

        if missing_wiki or missing_std:
            all_missing[str(note.relative_to(vault))] = missing_wiki + missing_std

        if text == original:
            continue

        total_changed += 1
        if args.dry_run:
            print(f"[DRY-RUN] Would update: {note.relative_to(vault)}")
        else:
            note.write_text(text, encoding="utf-8")
            print(f"Updated: {note.relative_to(vault)}")

    print(f"\n{'Dry-run ' if args.dry_run else ''}complete. {total_changed} note(s) changed out of {len(notes)}.")

    if all_missing:
        print("\nMissing attachments (could not be resolved):")
        for note_path, names in sorted(all_missing.items()):
            print(f"  {note_path}:")
            for name in names:
                display = name if len(name) <= 200 else name[:200] + "..."
                print(f"    - {display}")
    else:
        print("\nNo missing attachments found.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
