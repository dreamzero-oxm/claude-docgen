# claude-docgen

> Claude Code plugin marketplace—currently ships one plugin: **docgen**, a **flow-centric** multi-agent generator for code documentation. It discovers entry points, walks each call chain depth-first into an end-to-end flow document, adversarially reviews every flow against the source, writes per-directory `CLAUDE.md` context guides, and maintains a progressive-disclosure glossary. Multilingual output (default Simplified Chinese), incremental updates via git diff + sha256, and resume on interruption.

## What is this

- **Repo shape**: a Claude Code [Plugin Marketplace](https://docs.claude.com/en/docs/claude-code/plugins). Add the marketplace once, install plugins from it on demand.
- **Current plugin**: `docgen`
  - One slash command: `/docgen` (the orchestrator; runs in the main thread)
  - Three leaf subagents: `docgen-flow` (DFS call-chain → flow doc), `docgen-flow-review` (adversarial fact-check), `docgen-dir` (per-directory `CLAUDE.md`)
  - One Skill: lets natural language like "trace the login API call chain" trigger the same flow
  - Three deterministic hooks (SubagentStart / PreToolUse / SubagentStop): inject constraints, guard write paths, mechanically validate flow docs—zero-token
- **Output**: under your project's `docs/`—flow docs in `docs/flows/`, a glossary in `docs/glossary/`, a top-level `docs/README.md` index—plus a `CLAUDE.md` context guide next to each documented source directory.

## What changed in 0.4.0 (flow-centric rewrite)

Previous versions documented the repo **file by file**. 0.4.0 reorganizes around **execution flows**:

- The unit of documentation is now an **entry point + its call chain** (a "flow"), not a single file. A flow doc narrates the path from, say, `POST /api/v1/login` down through every function it calls, with inlined code, provenance tags on each hop, and honest "couldn't follow" markers at dynamic-dispatch boundaries.
- Each flow is **adversarially reviewed**: an independent subagent re-reads the source to confirm every call edge is real (a fabricated edge poisons the graph). Unconverged flows are kept with a ⚠️ banner, never silently shipped.
- Directory docs moved from `README.md` (an index) to **`CLAUDE.md` (a context guide)**—Claude Code auto-loads these, so a developer working in a directory gets its purpose, key files, and the flows passing through it as ambient context. Existing hand-written `CLAUDE.md` is protected: docgen only edits inside a `<!-- BEGIN/END docgen:auto -->` block.
- A **coverage ledger** tracks every candidate file; files no flow touched are listed explicitly in the report (honesty over false completeness).
- A **progressive-disclosure glossary** (`docs/glossary/`): a light L0 index + one file per term in `terms/`, loaded on demand.

> ⚠️ The state file is now **v3** and not convertible from the old per-file v1/v2. The first run on an old state file will ask you to `--force` a rebuild.

## Architecture

```
user ──/docgen──► main thread (orchestrator)
                    │   • discover entry points (heuristic + --entry)
                    │   • maintain <root>/docs/.docgen-state.json (v3) + coverage ledger
                    │   • per-flow pipeline: generate → review → rewrite (independent, parallel)
                    │   • back-fill review status / banners; merge glossary; write docs/README.md
                    ├──Task──► docgen-flow        × N   (one per entry; DFS call chain → flow doc)
                    ├──Task──► docgen-flow-review × ≥N  (independent adversarial source check)
                    └──Task──► docgen-dir         × M   (one per directory; CLAUDE.md context guide)

  deterministic shell hooks (zero token):
    SubagentStart  → inject each subagent's shared constraints
    PreToolUse     → deny out-of-bounds writes (run-gated; never touches unrelated writes)
    SubagentStop   → mechanically validate each flow doc before it returns
```

> Claude Code constraint: subagents cannot spawn other subagents. So all orchestration—including the review loop—stays in the slash command's main thread; the plugin ships three *leaf* subagents only.

## Install

### Option A: from GitHub

```bash
/plugin marketplace add dreamzero-oxm/claude-docgen
/plugin install docgen@claude-docgen
```

### Option B: from a local path (development / air-gapped)

```bash
/plugin marketplace add /path/to/claude-docgen
/plugin install docgen@claude-docgen
```

Open a fresh Claude Code conversation after install; `/docgen` is now available.

## Update

```bash
/plugin marketplace update claude-docgen
/plugin install docgen@claude-docgen
```

If you installed from a local path, `git pull` (or copy files) in that directory, then reinstall. Restart your conversation after updating.

## Usage

```bash
/docgen pkg/auth                                     # auto-discover entries, default *.go, zh-CN
/docgen pkg/auth --entry='POST /api/v1/login'        # document only this entry's flow
/docgen pkg/auth --entry='AuthSvc.Login'             # entry by symbol
/docgen . --max-depth=8 --concurrency=4              # deeper DFS, capped parallelism
/docgen src --include='*.go' --include='*.py'        # multiple includes
/docgen . --exclude='**/generated/**'                # add an exclude
/docgen . --no-review                                # skip the adversarial review loop (faster)
/docgen . --no-glossary                              # skip glossary extraction
/docgen . --no-mermaid                               # text-tree call chains only
/docgen . --force                                    # ignore incremental, regenerate everything
/docgen src --lang=en-US                             # output in English
/docgen src --lang=英文                               # alias works → en-US
/docgen . --no-callgraph                             # grep-only, no gopls
/docgen . --no-shared                                # don't pre-extract shared nodes
/docgen . --shared-threshold=5               # hotspot fan-in threshold
/docgen . --profile=generic                  # pick an entry-discovery profile
/docgen --selftest                           # verify hook input fields, then exit
```

### Entry points

A flow starts at an **entry point**. By default `/docgen` auto-discovers them (priority order, Go + trpc first): trpc service registration → gin/net-http routes → `func main`/`init` → exported service-interface methods → cron/consumer registration → a generic exported-function fallback. Test files, comments, vendored/generated/mock code are filtered out (each filtered hit is logged).

- Pass `--entry='<METHOD /route>'` or `--entry='<Symbol>'` (repeatable) to document only specific entries; this **disables auto-discovery**.
- If discovery finds nothing, `/docgen` stops and asks you to specify `--entry=`.

Project root is resolved in order: `$DOCGEN_PROJECT_ROOT` → `git rev-parse --show-toplevel`. If both fail, `/docgen` asks you to set the env var or run inside a git repo.

## Output language (`--lang`)

Default is `zh-CN`. `--lang` accepts ISO codes or common aliases:

| You can pass | Normalized to |
|--------------|---------------|
| `zh` / `中文` / `简体中文` / `chinese` / `cn` / `zh-CN` | `zh-CN` |
| `zh-tw` / `繁体` / `繁體中文` / `traditional` | `zh-TW` |
| `en` / `english` / `英文` / `英语` / `en-US` | `en-US` |
| `ja` / `jp` / `日文` / `日本語` / `japanese` / `ja-JP` | `ja-JP` |
| `ko` / `韩文` / `한국어` / `korean` / `ko-KR` | `ko-KR` |
| `fr` / `法文` / `french` | `fr-FR` |
| `de` / `德文` / `german` | `de-DE` |
| any other string (e.g. `pt-BR`, `Spanish`) | passed through verbatim |

**Resolution order** (first hit wins): `--lang=` → `$DOCGEN_LANG` → `state.config.lang` (if state exists) → default `zh-CN`.

**Switching languages does not require `--force`**: the state file records each flow's `lang`; the next run regenerates only flows whose `lang` differs.

> ⚠️ `--lang` only affects **generated documentation content**. The orchestration layer (`/docgen`'s status, errors, progress) is fixed in **English**.

## Recommended settings snippet

`/docgen` calls a handful of read-only Bash commands during scheduling (`git`, `grep`, `sha256sum`, `wc`, `sed`, `mkdir`, `rm -rf` of the scratch dir, …). To avoid prompts, merge into `~/.claude/settings.json` (global) or project-local `.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(git rev-parse:*)",
      "Bash(git -C *:*)",
      "Bash(git diff:*)",
      "Bash(git ls-files:*)",
      "Bash(grep:*)",
      "Bash(test:*)",
      "Bash(sed:*)",
      "Bash(tr:*)",
      "Bash(sha256sum:*)",
      "Bash(awk:*)",
      "Bash(wc:*)",
      "Bash(mkdir:*)",
      "Bash(rm -rf *docs/.docgen-scratch*)",
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

These allow read-only / computational operations plus cleanup of docgen's own volatile scratch directory—no write or delete on your source code.

## State file (v3)

After each run, state lives at `<project_root>/docs/.docgen-state.json`:

```json
{
  "version": 3,
  "last_run": "2026-06-26T12:34:56Z",
  "last_run_sha": "<git HEAD at last run>",
  "config": { "project_root": "/abs/...", "include": ["*.go"], "exclude": [],
              "lang": "zh-CN", "max_depth": 6 },
  "entries": [
    { "kind": "http_route", "signature": "POST /api/v1/login",
      "file": "handler/auth.go", "symbol": "Login", "slug": "post_api_v1_login" }
  ],
  "flows": {
    "post_api_v1_login": {
      "entry": { "kind": "http_route", "signature": "POST /api/v1/login",
                 "file": "handler/auth.go", "symbol": "Login" },
      "lang": "zh-CN",
      "status": "review_passed",
      "attempts": 1,
      "flow_doc_path": "docs/flows/post_api_v1_login.md",
      "touched_files": { "handler/auth.go": "<sha256>", "service/auth.go": "<sha256>" },
      "review": { "status": "passed", "rounds": 1, "last_issues": [] },
      "generated_at": "2026-06-26T12:34:56Z"
    }
  },
  "directories": {
    "handler": { "lang": "zh-CN", "status": "done", "claude_md_path": "handler/CLAUDE.md",
                 "flows_through": ["post_api_v1_login"], "uncovered_files": [],
                 "generated_at": "..." }
  },
  "file_to_flows": { "handler/auth.go": ["post_api_v1_login"] },
  "dir_to_flows":  { "handler": ["post_api_v1_login"] },
  "coverage": { "candidates_total": 42, "touched": 38, "uncovered": ["util/unused.go"] },
  "glossary": { "terms_count": 12, "l0_path": "docs/glossary/GLOSSARY.md", "generated_at": "..." }
}
```

Highlights:

- **Flow is the atomic unit** of incremental + resume. A flow is regenerated whole when any file it touched changes (`file_to_flows` reverse index + sha256 second-confirm); there is no mid-flow checkpoint.
- **Terminal statuses** (`review_passed` / `review_unconverged` / `orphaned`) are skipped on resume; everything else re-runs.
- **Coverage ledger** is refreshed every run, including incremental—files no flow touched are listed in `docs/README.md`.
- **Per-flow `lang`** drives language-switch regeneration without `--force`.
- Re-running after an interruption resumes automatically; `--force` or deleting the state file forces a full rebuild.

## FAQ

**Q: What's a "flow" exactly?**
A: An entry point (HTTP/RPC route, `main`, exported service method, cron/consumer) plus the call chain it triggers, walked depth-first. The flow doc narrates that chain end to end—so you can understand the behavior without opening the source.

**Q: What if the call chain can't be followed statically (interfaces, trpc dispatch, reflection)?**
A: `docgen-flow` marks the break honestly (`⚠️ couldn't follow`) and lists grep'd candidate implementations—it never fabricates an edge. The reviewer enforces this.

**Q: A file isn't reachable from any entry point. Is it documented?**
A: Not with its own flow doc, but it's tracked in the coverage ledger and listed under "uncovered files" in `docs/README.md` and the relevant directory's `CLAUDE.md`. (A `--with-file-docs` fallback was considered and deferred—the ledger already prevents silent omission.)

**Q: Will docgen overwrite my hand-written `CLAUDE.md`?**
A: No. It only writes inside a `<!-- BEGIN/END docgen:auto -->` block. If your file has no such block, docgen appends one at the end and leaves your content untouched.

**Q: Can I skip the review loop / glossary / Mermaid?**
A: Yes—`--no-review`, `--no-glossary`, `--no-mermaid`. Review, glossary, and Mermaid are all on by default.

**Q: What happens if I Ctrl-C mid-run?**
A: Rerun the same `/docgen <path>`. Flows in a terminal status are skipped; the rest re-run whole. The scratch directory is wiped and recreated at the start of each run.

**Q: My state file is corrupt / it's an old per-file state.**
A: Delete `<root>/docs/.docgen-state.json` (or pass `--force`). v1/v2 per-file state is not convertible to the v3 flow model—a rebuild is required.

**Q: Can `/docgen`'s status reports be in another language?**
A: No. Only the *generated documentation* follows `--lang`; the orchestration layer is fixed in English.

**Q: docgen 怎么减少公共节点（鉴权中间件等）的重复文档/成本？**
A: 默认开启「共享节点」：用 gopls 调用图算 fan-in，把被多条流程复用的热点先单独成文（`docs/flows/_shared/`），业务流程走到它就打链接、不重复展开。`--no-shared` 关闭，`--shared-threshold=N` 调阈值。

**Q: 没装 gopls / 不是 Go 仓库怎么办？**
A: 调用图 provider 探测不到 gopls 会自动降级到 grep 启发式（如实标 `[推断:grep]`），或显式 `--no-callgraph`。`--selftest` 可验证当前环境 hook 行为。

## Repository layout

```
claude-docgen/
├── .claude-plugin/
│   └── marketplace.json              # marketplace manifest
├── plugins/
│   └── docgen/
│       ├── .claude-plugin/
│       │   └── plugin.json           # plugin manifest (registers hooks)
│       ├── commands/docgen.md        # slash command (orchestrator)
│       ├── agents/
│       │   ├── docgen-flow.md        # DFS call-chain → flow doc
│       │   ├── docgen-flow-review.md # adversarial fact-check (judge only)
│       │   └── docgen-dir.md         # per-directory CLAUDE.md context guide
│       ├── hooks/hooks.json          # SubagentStart / PreToolUse / SubagentStop registration
│       ├── scripts/hooks/            # the three hook shell scripts + shared helper
│       ├── skills/docgen/SKILL.md    # natural-language trigger
│       └── README.md                 # plugin README
├── README.md                          # this file
├── LICENSE                            # MIT
└── .gitignore
```

## License

MIT — see [LICENSE](./LICENSE).
