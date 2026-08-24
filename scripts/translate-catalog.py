#!/usr/bin/env python3
"""Translate untranslated Localizable.xcstrings keys via a LOCAL model.

Uses LM Studio (or any OpenAI-compatible endpoint) — no cloud, matching
SwiftMaestro's privacy model. Entries written by this script are marked
"needs_review" (vs "translated" for human-written ones) so a native speaker
can audit them in Xcode before release.

Usage:
    python3 scripts/translate-catalog.py                      # all missing, all langs
    python3 scripts/translate-catalog.py --lang ja fr de      # specific languages
    python3 scripts/translate-catalog.py --endpoint http://100.x.y.z:1234 --model qwen3.5-122b
    python3 scripts/translate-catalog.py --dry-run            # show what would translate

Resumable: keys that already have ANY localization entry for a language are
skipped (delete an entry to force re-translation).
"""

import argparse
import concurrent.futures
import json
import sys
import threading
import time
import urllib.request

CATALOG = "Sources/Resources/Localizable.xcstrings"

# Never translate these (brand/product tokens).
GLOSSARY_KEEP = [
    "WhatsApp", "Discord", "MCP", "NDI", "MaestroDB", "MaestroDAM",
    "MaestroDocs", "MaestroBooks", "SwiftWeaver", "SwiftBrowser",
    "SwiftMaestro", "Maestro", "Stocky", "Blocky", "AirPlay", "Keychain",
    "Whisper", "Obsidian",
]

LANG_NAMES = {
    "ja": "Japanese", "zh-Hans": "Simplified Chinese", "zh-Hant": "Traditional Chinese",
    "ko": "Korean", "de": "German", "fr": "French", "es": "Spanish (Spain)",
    "es-419": "Latin American Spanish", "it": "Italian", "pt-BR": "Brazilian Portuguese",
    "pt-PT": "European Portuguese", "nl": "Dutch", "ru": "Russian", "ar": "Arabic",
    "hi": "Hindi", "th": "Thai", "vi": "Vietnamese", "id": "Indonesian",
    "tr": "Turkish", "pl": "Polish", "sv": "Swedish", "da": "Danish",
    "nb": "Norwegian Bokmål", "fi": "Finnish", "cs": "Czech", "el": "Greek",
    "he": "Hebrew", "hu": "Hungarian", "ro": "Romanian", "uk": "Ukrainian",
}

BATCH = 20  # keys per request
WORKERS = 6  # user-requested; server advertises 4 contexts, extras queue and fill instantly

save_lock = threading.Lock()


def translate_batch(endpoint: str, model: str, lang: str, keys: list[str]) -> dict[str, str]:
    """One chat completion translating a batch of UI strings. Returns {key: translation}."""
    lang_name = LANG_NAMES[lang]
    glossary = ", ".join(GLOSSARY_KEEP)
    keys_json = json.dumps(keys, ensure_ascii=False)
    prompt = (
        f"Translate these macOS app UI strings from English to {lang_name}. "
        f"Output ONLY a JSON object mapping each key to its translation. "
        f"Never translate these brands: {glossary}. "
        f"Preserve %lld/%@ specifiers, … and \\n exactly. "
        f"Use Apple's standard {lang_name} UI vocabulary; stay concise.\n"
        f"Keys: {keys_json}"
    )
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.3,
    }).encode()
    req = urllib.request.Request(
        f"{endpoint.rstrip('/')}/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        payload = json.loads(resp.read())
    text = payload["choices"][0]["message"]["content"].strip()
    # Strip code fences if the model wraps the JSON.
    if text.startswith("```"):
        text = text.split("```")[1]
        if text.startswith("json"):
            text = text[4:]
    result = json.loads(text)
    return {str(k): str(v) for k, v in result.items()}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", default="http://localhost:1234")
    ap.add_argument("--model", default="qwen3.5-122b")
    ap.add_argument("--lang", nargs="*", default=sorted(LANG_NAMES))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--catalog", default=CATALOG)
    args = ap.parse_args()

    catalog = json.load(open(args.catalog, encoding="utf-8"))
    strings = catalog["strings"]

    for lang in args.lang:
        if lang not in LANG_NAMES:
            print(f"!! unknown language '{lang}'", file=sys.stderr)
            continue
        missing = [
            key for key, entry in strings.items()
            if lang not in entry.get("localizations", {})
        ]
        if not missing:
            print(f"{lang}: complete — nothing to do")
            continue
        print(f"{lang}: {len(missing)} keys to translate")
        if args.dry_run:
            continue

        done = 0
        batches = [missing[i:i + BATCH] for i in range(0, len(missing), BATCH)]

        def work(batch: list[str]) -> dict[str, str]:
            for attempt in range(3):
                try:
                    return translate_batch(args.endpoint, args.model, lang, batch)
                except Exception as exc:
                    print(f"  batch attempt {attempt + 1} failed: {exc}", file=sys.stderr)
                    if attempt == 2:
                        raise
                    time.sleep(2 * (attempt + 1))
            return {}

        def save():
            with save_lock:
                with open(args.catalog, "w", encoding="utf-8") as f:
                    json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
                    f.write("\n")

        # The server runs 4 parallel contexts; serial requests waste 3 of them.
        with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
            futures = {pool.submit(work, batch): batch for batch in batches}
            for future in concurrent.futures.as_completed(futures):
                batch = futures[future]
                try:
                    result = future.result()
                except Exception as exc:
                    print(f"  batch dropped after retries: {exc}", file=sys.stderr)
                    continue
                with save_lock:
                    for key in batch:
                        if key in result and result[key].strip():
                            entry = strings[key]
                            entry.setdefault("localizations", {})[lang] = {
                                "stringUnit": {"state": "needs_review", "value": result[key].strip()}
                            }
                            done += 1
                save()
                print(f"  {done}/{len(missing)}")

        print(f"{lang}: wrote {done} entries (state=needs_review)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
