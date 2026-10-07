#!/usr/bin/env python3
"""
Migrate the legacy ~/.ai-context/data/global/ monolithic markdown context
into the unified ~/.ai-context/memory/ store as structured entries.

The script:
1. Creates a timestamped backup of data/global/.
2. Parses frontmatter-delimited entries from each .md/.txt file.
3. Writes JSON + Markdown companion entries under memory/knowledge/migrated-global/.
4. Leaves the original files in place (review and delete manually after verification).
"""

import os
import re
import json
import uuid
import shutil
from datetime import datetime, timezone
from pathlib import Path

DATA_GLOBAL = Path.home() / ".ai-context" / "data" / "global"
MEMORY_ROOT = Path.home() / ".ai-context" / "memory"
BACKUP_ROOT = Path.home() / ".ai-context" / "data"


def slugify(text: str) -> str:
    s = re.sub(r"[^\w\s-]", "", text).strip().lower()
    s = re.sub(r"[-\s]+", "-", s)
    return s[:80]


def parse_entries(path: Path) -> list[dict]:
    """Parse a file into frontmatter-delimited entries."""
    text = path.read_text(encoding="utf-8")
    # Split on lines that are exactly '---' (frontmatter delimiter)
    parts = re.split(r"\n---\s*\n", text)
    entries = []
    for part in parts:
        part = part.strip()
        if not part:
            continue
        # Extract frontmatter if present
        fm_match = re.match(r"^---\s*\n(.*?)\n---\s*\n(.*)$", part, re.DOTALL)
        if fm_match:
            fm_text = fm_match.group(1)
            body = fm_match.group(2).strip()
        else:
            fm_text = ""
            body = part
        fm = {}
        for line in fm_text.splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                fm[k.strip().lower()] = v.strip()
        entries.append({"fm": fm, "body": body, "source_file": path.name})
    return entries


def kind_for_entry(entry: dict) -> str:
    fm = entry["fm"]
    t = fm.get("type", "note").lower()
    mapping = {
        "decision": "decisions",
        "todo": "todos",
        "error": "errors",
        "session-update": "sessions",
        "session": "sessions",
        "note": "notes",
        "prompt": "prompts",
    }
    return mapping.get(t, "notes")


def title_for_entry(entry: dict) -> str:
    body = entry["body"]
    # First non-empty line, stripped of markdown heading chars
    for line in body.splitlines():
        line = line.strip()
        if line:
            return re.sub(r"^#+\s*", "", line)
    return entry["source_file"]


def write_entry(entry: dict, index: int) -> Path:
    fm = entry["fm"]
    body = entry["body"]
    source = fm.get("from", "migrated")
    ts = fm.get("timestamp", datetime.now(timezone.utc).isoformat())
    project = fm.get("project", "global")
    kind = kind_for_entry(entry)
    title = title_for_entry(entry)
    slug = f"{slugify(title)}-{index:04d}"
    out_dir = MEMORY_ROOT / "knowledge" / "migrated-global" / kind
    out_dir.mkdir(parents=True, exist_ok=True)

    uri = f"qwen://knowledge/migrated-global/{kind}/{slug}"
    entry_id = str(uuid.uuid4())
    tags = ["migrated", "global"]
    if project and project != "global":
        tags.append(project)

    json_path = out_dir / f"{slug}.json"
    md_path = out_dir / f"{slug}.md"

    json_path.write_text(
        json.dumps(
            {
                "id": entry_id,
                "uri": uri,
                "source": source,
                "timestamp": ts,
                "type": fm.get("type", "note"),
                "project": project,
                "content": body,
                "tags": tags,
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    md_content = f"""---
FROM: {source}
TIMESTAMP: {ts}
PROJECT: {project}
TYPE: {fm.get('type', 'note')}
URI: {uri}
---

{body}
"""
    md_path.write_text(md_content, encoding="utf-8")
    return json_path


def main() -> None:
    if not DATA_GLOBAL.exists():
        print(f"Nothing to migrate: {DATA_GLOBAL} does not exist.")
        return

    backup_name = f"global-backup-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    backup_path = BACKUP_ROOT / backup_name
    shutil.copytree(DATA_GLOBAL, backup_path, ignore_dangling_symlinks=True)
    print(f"Backed up {DATA_GLOBAL} -> {backup_path}")

    files = sorted(DATA_GLOBAL.rglob("*"))
    md_files = [p for p in files if p.is_file() and p.suffix in {".md", ".txt"}]

    total = 0
    for file_path in md_files:
        entries = parse_entries(file_path)
        for i, entry in enumerate(entries):
            if not entry["body"].strip() and not entry["fm"]:
                continue
            out = write_entry(entry, total)
            total += 1
            print(f"  wrote {out}")

    print(f"\nMigrated {total} entries from {len(md_files)} files.")
    print("Original files are still in place; delete manually after verifying.")


if __name__ == "__main__":
    main()
