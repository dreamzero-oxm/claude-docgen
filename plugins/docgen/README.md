# docgen

**Flow-centric** multi-agent generator for code documentation. It discovers entry points, walks each one's call chain depth-first into an **end-to-end flow document**, adversarially reviews every flow against the source, writes a **context-guide `CLAUDE.md`** in each touched directory, and maintains a **progressive-disclosure glossary**. Multilingual output (default Simplified Chinese), incremental updates via git diff + sha256, and resume on interruption.

## Install

```bash
/plugin marketplace add dreamzero-oxm/claude-docgen
/plugin install docgen@claude-docgen
```

## Usage

```bash
/docgen <path>                                # auto-discover entries, default *.go, zh-CN
/docgen <path> --entry='POST /api/v1/login'   # document only this entry's flow
/docgen <path> --max-depth=8                  # deeper DFS (default 6)
/docgen <path> --include='*.go' --include='*.py'
/docgen <path> --concurrency=4                # default 8
/docgen <path> --no-review                    # skip the adversarial review loop
/docgen <path> --no-glossary                  # skip glossary extraction
/docgen <path> --no-mermaid                   # text-tree call chains only
/docgen <path> --lang=en-US                   # output in English
/docgen <path> --force                        # full regeneration
```

Outputs land under `<project_root>/docs/`: flow docs in `docs/flows/`, glossary in `docs/glossary/`, top index `docs/README.md`, incremental state in `docs/.docgen-state.json`. A `CLAUDE.md` context guide is written next to each documented source directory (only inside a `<!-- BEGIN/END docgen:auto -->` block—hand-written content is preserved).

Full docs—`--lang` aliases, recommended `settings` snippet, v3 state schema, FAQ—see the repo root [README.md](../../README.md).

## Components

- `commands/docgen.md` — slash command (orchestrator; runs in the main thread, not a subagent)
- `agents/docgen-flow.md` — DFS call-chain analysis → one flow doc per entry
- `agents/docgen-flow-review.md` — independent adversarial fact-check of each flow (judge only, no writes)
- `agents/docgen-dir.md` — per-directory `CLAUDE.md` context guide (protects existing content)
- `skills/docgen/SKILL.md` — natural-language trigger for `/docgen`
- `hooks/hooks.json` + `scripts/hooks/*.sh` — three deterministic hooks (SubagentStart / PreToolUse / SubagentStop)

## License

MIT
