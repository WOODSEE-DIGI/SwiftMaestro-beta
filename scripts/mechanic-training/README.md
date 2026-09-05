# Mechanic Model Training Pipeline

Fine-tunes the bundled support model (Qwen3-4B-Instruct-2507-4bit) into a
SwiftMaestro specialist via LoRA, using data harvested from real failure
logs + the project's own docs/runbooks. 100% local: no teacher model, no
cloud calls — dataset generation is template/rule-based so it runs offline.

## Steps

```bash
# 1. Generate the training dataset (offline, fast)
./scripts/mechanic-training/generate_dataset.py
#    → dist/mechanic-training/dataset.jsonl  (chat-format messages)

# 2. Train (installs mlx-lm into the SwiftMaestro venv on first run)
./scripts/mechanic-training/train.sh
#    → LoRA adapters → fused → 4-bit → <model-directory>/models/swiftmaestro-models/SwiftMaestro-Mechanic-4bit
```

## Data sources (generate_dataset.py)

1. **Curated support scenarios** — hand-written failure→fix pairs baked into
   the generator (MCP setup/repair, model load failures, crash triage,
   settings restore, guardian interpretation, notarization, paths).
2. **Guardian log replay** — `tool-failures.jsonl` (healed records) become
   "what failed and how was it fixed" Q&A pairs.
3. **Doc grounding** — `docs/*.md`, `AGENTS.md`, `README.md` chunked into
   passages with template questions ("Where does SwiftMaestro store X?",
   "How do I fix Y?"). Grounds the model in real paths and procedures.

## After training

- Point the Mechanic agent at the fine-tuned dir (it defaults to the stock
  Qwen3-4B when the fine-tuned one is absent — ModelCatalog.mechanicModelID).
- To bundle the fine-tuned model instead of stock: overwrite
  `<model-directory>/models/swiftmaestro-models/Qwen3-4B-Instruct-2507-4bit`
  contents, or add a catalog entry with a new id and set the Mechanic's
  model override to it.
- Evaluate: `train.sh --eval` runs 20 held-out support questions through
  both stock and fine-tuned models and prints answers side by side.
