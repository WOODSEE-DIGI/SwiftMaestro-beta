#!/usr/bin/env python3
"""Merge a sharded translation catalog back into the main Localizable.xcstrings.

After a split run (e.g. instance B translating its languages against
logs/catalog-B.xcstrings), merge ONLY the languages that shard was assigned
into the main catalog — never overwriting other languages' entries.

Usage:
    python3 scripts/merge-catalog-shard.py logs/catalog-B.xcstrings --langs ko es it pt-BR ru
"""

import argparse
import json
import sys

MAIN = "Sources/Resources/Localizable.xcstrings"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("shard")
    ap.add_argument("--langs", nargs="+", required=True)
    ap.add_argument("--catalog", default=MAIN)
    args = ap.parse_args()

    main = json.load(open(args.catalog, encoding="utf-8"))
    shard = json.load(open(args.shard, encoding="utf-8"))

    merged = 0
    for key, entry in shard["strings"].items():
        locs = entry.get("localizations", {})
        for lang in args.langs:
            if lang in locs:
                target = main["strings"].setdefault(key, {})
                target.setdefault("localizations", {})[lang] = locs[lang]
                merged += 1

    with open(args.catalog, "w", encoding="utf-8") as f:
        json.dump(main, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    print(f"merged {merged} entries for {args.langs} into {args.catalog}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
