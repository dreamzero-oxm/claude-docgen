# claude-docgen

> Claude Code plugin marketplace—currently ships one plugin: **docgen**, a multi-agent generator for detailed markdown documentation of code repos. Multilingual output (default Simplified Chinese), incremental updates via git diff + sha256, and resume on interruption.

## What is this

- **Repo shape**: a Claude Code [Plugin Marketplace](https://docs.claude.com/en/docs/claude-code/plugins). Add the marketplace once, install plugins from it on demand.
- **Current plugin**: `docgen`
  - One slash command: `/docgen`
  - Two leaf subagents: `docgen-file` (writes per-file docs), `docgen-dir` (writes per-directory MOCs)
  - One Skill: lets natural language like "write docs for this directory" trigger the same flow
- **Output**: under your project's `docs/`, the plugin mirrors the source tree—each source file becomes `<file>.md`, each directory gets a `README.md`, and the top-level `docs/README.md` is the global index.

## Three-layer architecture

```
user ──/docgen──► main thread (orchestrator)
                    │   • scan candidates / compute sha256 / decide incremental work
                    │   • maintain <root>/docs/.docgen-state.json
                    │   • write top-level docs/README.md itself
                    ├──Task──► docgen-file × N  (parallel within a directory, ≤ concurrency)
                    │            writes each source file's .md
                    └──Task──► docgen-dir × 1  (once per directory)
                                 writes the directory's README.md MOC
```

> Claude Code constraint: subagents cannot spawn other subagents. So the orchestration must stay in the slash command's main thread; this plugin only ships two leaf subagents (`docgen-file` / `docgen-dir`)—there is no separate orchestrator agent.

## Install

### Option A: from GitHub

```bash
# Add the marketplace
/plugin marketplace add dreamzero-oxm/claude-docgen

# Install the docgen plugin
/plugin install docgen@claude-docgen
```

### Option B: from a local path (development / air-gapped)

```bash
/plugin marketplace add /path/to/claude-docgen
/plugin install docgen@claude-docgen
```

Open a fresh Claude Code conversation after install; `/docgen` is now available.

## Usage

```bash
/docgen pkg/auth/handlers                            # default *.go, excludes test/vendor/.git, output zh-CN
/docgen src --include='*.go' --include='*.py'        # multiple includes
/docgen . --exclude='**/generated/**'                # add an exclude
/docgen . --concurrency=4                            # cap parallelism (default 8)
/docgen . --force                                    # ignore incremental, regenerate everything
/docgen lua --include='*.lua'                        # any language, just give it a glob
/docgen src --lang=en-US                             # output in English
/docgen src --lang=ja-JP                             # output in Japanese
/docgen src --lang=英文                               # alias works → en-US
```

Project root is resolved in this order:

1. Environment variable `$DOCGEN_PROJECT_ROOT`
2. `git rev-parse --show-toplevel`

If both fail, `/docgen` asks you to set the env var or run inside a git repo.

## Output language (`--lang`)

Documentation language is configurable; **default is `zh-CN` (Simplified Chinese)**. `--lang` accepts ISO codes or common aliases:

| You can pass | Normalized to |
|--------------|---------------|
| `zh` / `中文` / `简体中文` / `chinese` / `cn` / `zh-CN` | `zh-CN` |
| `zh-tw` / `繁体` / `繁體中文` / `traditional` | `zh-TW` |
| `en` / `english` / `英文` / `英语` / `en-US` | `en-US` |
| `ja` / `jp` / `日文` / `日本語` / `japanese` / `ja-JP` | `ja-JP` |
| `ko` / `韩文` / `한국어` / `korean` / `ko-KR` | `ko-KR` |
| `fr` / `français` / `法文` / `french` | `fr-FR` |
| `de` / `deutsch` / `德文` / `german` | `de-DE` |
| any other string (e.g. `pt-BR`, `Spanish`) | passed through verbatim; the model interprets it |

**Resolution order** (first hit wins):

1. CLI flag `--lang=...`
2. Environment variable `$DOCGEN_LANG`
3. `state.json.config.lang` (remembered from the previous run, only if state already exists)
4. Built-in default `zh-CN`

Example: with `DOCGEN_LANG=en-US` exported in your shell, all `/docgen` invocations default to English unless `--lang=` overrides.

**Switching languages does not require `--force`**: state.json records each file's `lang` on generation. The next run regenerates only the entries whose `lang` differs from this run's `lang`; entries in unrelated languages are left alone (but note: under a single `docs/` tree there is only one `<src>.md` per source file—it gets overwritten).

> ⚠️ `--lang` only affects **generated documentation content**. The orchestration layer (`/docgen`'s status reports, error messages, progress output) is fixed in **English**.

## Recommended settings snippet

`/docgen` calls a handful of read-only Bash commands during scheduling: `git`, `sha256sum`, `wc`, `sed`, etc. To avoid being prompted on every run, merge the snippet below into your `~/.claude/settings.json` (global) or project-local `.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(git rev-parse:*)",
      "Bash(git -C *:*)",
      "Bash(git diff:*)",
      "Bash(git ls-files:*)",
      "Bash(test:*)",
      "Bash(echo:*)",
      "Bash(sed:*)",
      "Bash(tr:*)",
      "Bash(sha256sum:*)",
      "Bash(awk:*)",
      "Bash(wc:*)",
      "Bash(mkdir:*)",
      "Bash(dirname:*)",
      "Bash(basename:*)",
      "Bash(cat:*)",
      "Bash(ls:*)",
      "Bash(find:*)",
      "Bash(printenv:*)",
      "Skill(docgen)"
    ]
  }
}
```

These entries only allow read-only / computational operations—no write or delete capabilities on your source code.

## State file

After each run, state lives at `<project_root>/docs/.docgen-state.json`:

```json
{
  "version": 2,
  "files": {
    "<source-relative-path>": {
      "sha256": "<64 hex>",
      "lang": "zh-CN",
      "status": "done | failed_permanent",
      "attempts": 1,
      "doc_path": "docs/<mirrored-path>.md",
      "generated_at": "2026-05-24T12:34:56Z"
    }
  },
  "directories": {
    "<directory-relative-path>": {
      "lang": "zh-CN",
      "status": "done",
      "moc_path": "docs/.../README.md",
      "generated_at": "...",
      "child_files": 14,
      "child_subdirs": 2
    }
  },
  "config": {
    "project_root": "/abs/...",
    "include": ["*.go"],
    "exclude": [],
    "lang": "zh-CN"
  },
  "last_run": "..."
}
```

Highlights:

- Skips unchanged files based on git diff + sha256
- **Each entry records its generation `lang`**—switching `--lang` automatically queues mismatched entries for regeneration
- Re-running `/docgen` after an interruption resumes automatically (just re-reads state)
- To force a full regen: `/docgen <path> --force` or delete the state file
- **v1 → v2 auto-migration**: the first run on a v0.1.0 state file backfills `lang: "zh-CN"` and bumps `version` to 2; no manual step required

## FAQ

**Q: Can I generate docs in English / Japanese / any other language?**
A: Yes. Pass `--lang=en-US` (English), `--lang=ja-JP` (Japanese), and so on. See "Output language" above.

**Q: What happens if I Ctrl-C in the middle of a run?**
A: Just rerun the same `/docgen <path>`. Files already marked `done` are skipped; the rest go back into the work set.

**Q: My state file is corrupt—how do I recover?**
A: Delete `<root>/docs/.docgen-state.json`. The next run will start from a clean slate (full regeneration).

**Q: I switched from zh-CN to en-US—what happens to my old Chinese docs?**
A: They get overwritten. There is one `<src>.md` per source file under `docs/`, and the state file's per-entry `lang` ensures mismatched entries enter the work set on the next run; the new content replaces the old. If you want bilingual docs (`<src>.zh.md` and `<src>.en.md` side by side), please open an issue—it's not supported in v0.x.

**Q: Can `/docgen`'s status reports also be customized?**
A: Not currently. The orchestration layer (progress, success report, error messages) is fixed in English. Only the *generated documentation* in `docs/` follows `--lang`. If you want bilingual orchestration output, please open an issue.

## Repository layout

```
claude-docgen/
├── .claude-plugin/
│   └── marketplace.json           # marketplace manifest
├── plugins/
│   └── docgen/
│       ├── .claude-plugin/
│       │   └── plugin.json        # plugin manifest
│       ├── commands/docgen.md     # slash command (orchestrator)
│       ├── agents/
│       │   ├── docgen-file.md     # per-file documentation subagent
│       │   └── docgen-dir.md      # per-directory MOC subagent
│       ├── skills/docgen/SKILL.md # natural-language trigger
│       └── README.md              # plugin README
├── README.md                       # this file
├── LICENSE                         # MIT
└── .gitignore
```

## License

MIT — see [LICENSE](./LICENSE).
