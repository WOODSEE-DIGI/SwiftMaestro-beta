#!/usr/bin/env python3
"""Generate the Mechanic fine-tuning dataset — fully offline, rule-based.

Sources:
  1. Curated support scenarios (below)
  2. ToolCallGuardian failure log (healed records -> Q&A)
  3. Project docs grounding (docs/, AGENTS.md, README.md)

Output: dist/mechanic-training/dataset.jsonl — chat format {"messages":[...]}
"""
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "dist" / "mechanic-training" / "dataset.jsonl"
GUARDIAN_LOG = Path.home() / "Library/Application Support/SwiftMaestro/tool-failures.jsonl"
DOCS_DIRS = [ROOT / "docs", ROOT]
DOC_FILES = ["AGENTS.md", "README.md"]

SYSTEM = (
    "You are Mechanic, SwiftMaestro's built-in support engineer. You diagnose internal "
    "problems, help configure MCP servers and models, and restore the app to its last "
    "known working condition. Be precise, use exact paths, and never run destructive "
    "actions without user approval."
)


def scenario(q, a):
    return {"messages": [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": q},
        {"role": "assistant", "content": a},
    ]}


# ── 1. Curated support scenarios ─────────────────────────────────────────
SCENARIOS = [
    ("The app updated and now my settings are broken. Can you fix it?",
     "Yes. First I'll snapshot the CURRENT (broken) state with settings_backup_now so we "
     "can compare or undo, then I'll restore the last known-good settings with "
     "settings_restore_backup. The restore reverts model selection, authorized folders, "
     "feature toggles, and tuning to the backed-up state. A restart may be needed for "
     "everything to take effect. Want me to proceed?"),
    ("My MCP server isn't working. The tools never show up.",
     "Let me check the registry at ~/.ai-context/mcp-registry/mcp-servers.json for your "
     "server's entry, then verify the command path exists and its env vars are set. Common "
     "causes after an OS or Homebrew update: the node/python binary moved, the server "
     "package needs `npm install` in its folder, or an API key env var is missing. I'll "
     "also check self_healing_failures for MCP tool errors from your server."),
    ("A model won't load — it just spins.",
     "I'll check three things: the model path exists under the models root "
     "(~/Ai-models/models/), free unified memory via system_health (a 122B model needs "
     "~65 GB and won't load while another large model is resident), and "
     "self_healing_failures for MLX allocation errors. If the path is stale, I'll point "
     "you at Settings → Models to re-scan or re-download."),
    ("The agent says it did things but nothing actually happened.",
     "That's a false-claim failure. I'll look at self_healing_failures for the tool that "
     "was supposed to run — if the model emitted a malformed tool call, the guardian log "
     "shows the failure class. Fixes: switch to a tool-verified model in Settings → Models, "
     "or let the guardian's learned quirks (model-quirks.json) handle that model's "
     "argument habits — they promote automatically after two healed failures."),
    ("SwiftMaestro crashed. What happened?",
     "I'll run diagnose_crash for the SwiftMaestro process — that bundles the latest "
     "crash report (exception type, crashed-thread backtrace) with recent console log "
     "output and a system health snapshot, then explain the most likely cause in plain "
     "language and propose a fix."),
    ("How do I add a new MCP server?",
     "Add an entry to ~/.ai-context/mcp-registry/mcp-servers.json with the server's name, "
     "command, args, and any env vars (API keys go in as secret:// references, never "
     "plaintext), then run ~/.ai-context/scripts/sync-mcp.sh to push the config to all "
     "tools. I can write the entry for you if you tell me the server's package or path."),
    ("What does the Self-Healing settings tab show?",
     "Settings → Self-Healing shows the ToolCallGuardian's activity: total tool-call "
     "failures, heal rate, failures by class (parse, argument, transient environment, "
     "blocking environment), the learned per-model quirks, and the recent failure log "
     "with the path to the full JSONL log."),
    ("Something is using all my memory and everything is slow.",
     "I'll run system_health to see memory pressure (wired/active/compressed), the top "
     "CPU processes, and load average. If a large model is resident (e.g. the 122B needs "
     "~65 GB), unloading it or switching to a smaller model usually fixes it. SwiftMaestro "
     "never loads a second large model while a 100B+ model is resident."),
    ("Where does SwiftMaestro keep its data?",
     "App data: ~/Library/Application Support/SwiftMaestro/ (settings, secrets index, "
     "guardian log, learned model quirks, settings backups, the DAM catalog). Shared AI "
     "memory: ~/.ai-context/memory/. Models: ~/Ai-models/models/ by default (configurable "
     "in Settings → Models). Crash reports: ~/Library/Logs/DiagnosticReports/."),
    ("The vision proxy says model not found.",
     "The proxy model path is stale. It resolves in order: your configured path, then "
     "~/Ai-models/models/swiftmaestro-models/Qwen3-VL-8B-Instruct-4bit, then "
     "mlx-community/Qwen3-VL-8B-Instruct-4bit under the models root. If none exist, "
     "re-download from Settings → Vision Proxy. I can check which path exists right now."),
    ("How do I know if the Mechanic model is installed?",
     "The Mechanic's bundled model lives at ~/Ai-models/models/swiftmaestro-models/"
     "Qwen3-4B-Instruct-2507-4bit. If that folder is missing, download it from "
     "Settings → Models (it's listed as 'SwiftMaestro Mechanic (Qwen3 4B)') — the "
     "Mechanic agent falls back to your default model until then."),
    ("A tool keeps saying my path isn't authorized.",
     "The folder isn't in your authorized list. Add it in Settings → Context, or ask me "
     "to work within an already-authorized directory. If the path LOOKS right, invisible "
     "characters (non-breaking spaces) in a pasted path are a known cause — the agent's "
     "path normalization handles those, so retry the action after re-adding the folder."),
]


# Paraphrase prefixes expand each curated scenario so the model learns the
# PLAYBOOK, not one phrasing of the question.
PARAPHRASES = [
    ("{}", None),
    ("Help — {}", None),
    ("Quick question: {}", None),
    ("Something's wrong. {}", None),
    ("Can you walk me through this? {}", None),
    ("{}", "lower"),  # same text, lowercased first letter — casual typing
]


def curated():
    out = []
    for q, a in SCENARIOS:
        out.append(scenario(q, a))
        for template, mode in PARAPHRASES[1:]:
            variant = template.format(q)
            if mode == "lower":
                variant = variant[0].lower() + variant[1:]
            out.append(scenario(variant, a))
    return out


# ── 2. Guardian log replay ───────────────────────────────────────────────
def guardian_pairs():
    pairs = []
    if not GUARDIAN_LOG.exists():
        return pairs
    for line in GUARDIAN_LOG.read_text().splitlines():
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not record.get("healed"):
            continue
        tool = record.get("tool", "unknown")
        cls = record.get("failureClass", "unknown")
        strategy = record.get("strategy", "retry")
        q = (f"The {tool} tool failed with a {cls} error. What happens now, and should "
             f"I worry?")
        a = (f"No action needed — the ToolCallGuardian healed it automatically via "
             f"'{strategy}'. {cls} failures of this kind are retried or repaired "
             f"transparently, and if the same fix heals the same failure twice for your "
             f"model, it becomes a permanent learned quirk so the failure stops "
             f"happening at all. You can inspect the full record in "
             f"~/Library/Application Support/SwiftMaestro/tool-failures.jsonl.")
        pairs.append(scenario(q, a))
    return pairs


# ── 3. Doc grounding ─────────────────────────────────────────────────────
QUESTION_TEMPLATES = [
    ("how do I {}", "How to {}: {}"),
    ("how do i {}", None),
]


def doc_pairs():
    pairs = []
    sources = []
    for d in DOCS_DIRS:
        if d.is_dir():
            sources += list(d.glob("*.md"))
    for f in DOC_FILES:
        p = ROOT / f
        if p.exists():
            sources.append(p)

    seen = set()
    for path in sources:
        if path in seen:
            continue
        seen.add(path)
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        rel = path.name
        # Split into heading-delimited chunks; each chunk with substance
        # becomes a grounded Q&A.
        for chunk in re.split(r"\n#{1,3} ", text):
            chunk = chunk.strip()
            if len(chunk) < 200:
                continue
            title = chunk.splitlines()[0].lstrip("# ").strip()
            title = re.sub(r"[^\w\s/\-+.']", "", title)[:80]
            if not title:
                continue
            body = chunk[:1500]
            q = f"In SwiftMaestro, {title.lower()} — how does that work?"
            a = (f"From the project docs ({rel}):\n\n{body}\n\n"
                 f"That section of {rel} is the authoritative reference if you need "
                 f"more detail.")
            pairs.append(scenario(q, a))
    return pairs


def main():
    OUT.parent.mkdir(parents=True, exist_ok=True)
    dataset = curated() + guardian_pairs() + doc_pairs()

    # Dedupe by user question text.
    seen = set()
    unique = []
    for item in dataset:
        key = item["messages"][1]["content"]
        if key in seen:
            continue
        seen.add(key)
        unique.append(item)

    with OUT.open("w") as f:
        for item in unique:
            f.write(json.dumps(item) + "\n")
    print(f"Wrote {len(unique)} examples to {OUT}")
    print(f"  curated scenarios: {len(curated())} (12 scenarios × paraphrases)")
    print(f"  guardian replay:   {len(guardian_pairs())}")
    print(f"  doc grounding:     {len(unique) - len(SCENARIOS) - len(guardian_pairs())}")


if __name__ == "__main__":
    sys.exit(main())
