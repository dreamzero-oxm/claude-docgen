# docgen

Multi-agent generator for detailed markdown documentation of code repos. **Multilingual output (default Simplified Chinese)**, incremental updates via git diff + sha256, and resume on interruption.

## Install

```bash
/plugin marketplace add dreamzero-oxm/claude-docgen
/plugin install docgen@claude-docgen
```

## Usage

```bash
/docgen <path>                                    # default *.go, output zh-CN
/docgen <path> --include='*.go' --include='*.py'  # multiple includes
/docgen <path> --concurrency=4                    # default 8
/docgen <path> --lang=en-US                       # output in English
/docgen <path> --lang=ja-JP                       # output in Japanese
/docgen <path> --force                            # full regeneration
```

Docs land under `<project_root>/docs/`, mirroring the source tree. Incremental state (with per-file `lang`) is kept in `<project_root>/docs/.docgen-state.json`.

Full docs—`--lang` aliases, recommended `settings` snippet, FAQ—see the repo root [README.md](../../README.md).

## Components

- `commands/docgen.md` — slash command (orchestrator; runs in the main thread, not as a subagent)
- `agents/docgen-file.md` — writes single-file `.md` documentation
- `agents/docgen-dir.md` — writes per-directory `README.md` MOC
- `skills/docgen/SKILL.md` — lets natural language trigger `/docgen`

## License

MIT
