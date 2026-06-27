---
description: Flow-centric code documentation generator—discovers entry points, walks each call chain depth-first into an end-to-end flow doc, adversarially reviews it, writes per-directory CLAUDE.md context guides and a progressive-disclosure glossary; incremental + resume. Default zh-CN; --lang targets en-US / ja-JP / etc.
argument-hint: <path> [--entry=GLOB|SYMBOL] [--max-depth=N] [--include=GLOB] [--exclude=GLOB] [--concurrency=N] [--lang=CODE] [--no-glossary] [--no-review] [--max-review-rounds=N] [--no-mermaid] [--force]
allowed-tools: Read, Grep, Bash, Write, Edit
model: claude-sonnet-4-6
---

# /docgen —— flow-centric code documentation via slash-command self-orchestration

## Architectural premise (read this first)

**You (the conversation running `/docgen`) ARE the orchestrator.** A slash command runs in the **main conversation thread**, so you can call the `Task` (a.k.a. `Agent`) tool to spawn one layer of subagents. **Subagents cannot spawn other subagents** (hard Claude Code limit, per `https://code.claude.com/docs/en/sub-agents`)—so all orchestration, including the review loop, stays here in the main thread.

```
user → /docgen (you, main thread)
        │  parse args / locate project_root / resolve lang
        │  discover entry points (heuristic + --entry override)
        │  maintain <root>/docs/.docgen-state.json (v3)
        │  per-flow pipeline: generate → review → rewrite (independent, parallel)
        │  back-fill flow-doc header review status / banners
        │  merge docs/glossary/ (L0 index + L1 terms)
        │  write top-level docs/README.md
        ├──Task──► docgen-flow        × N   (one per entry; DFS along the call chain)
        ├──Task──► docgen-flow-review × ≥N  (independent adversarial source check)
        └──Task──► docgen-dir         × M   (one per directory; writes CLAUDE.md context guide)
```

The old per-file model (`docgen-file`) is gone. The organizing unit is now the **flow**: an entry point plus everything it calls. A lightweight **coverage ledger** still tracks every candidate file so nothing is silently dropped.

Deterministic shell hooks (zero token; registered in `hooks/hooks.json`) wrap the subagents: SubagentStart injects shared constraints, PreToolUse denies out-of-bounds writes, SubagentStop mechanically validates each flow doc before it returns. They are an optimization, not a correctness dependency—your orchestration must be correct even if hooks are disabled.

## Your hard responsibilities (do not cross the line)

| You **MUST** do | You **MUST NOT** do |
|-----------------|---------------------|
| Parse args, locate `project_root`, resolve `lang` | Read full source to write flow docs yourself |
| Discover entry points (heuristic + `--entry`) | Write any `docs/flows/*.md` yourself |
| Maintain the v3 state file + coverage ledger | Write any directory's `CLAUDE.md` yourself |
| Run each flow's generate→review→rewrite pipeline by **actually** calling `Task` | Edit content **outside** a CLAUDE.md `docgen:auto` block |
| Back-fill flow-doc header review status + banners (§ Step K) | Hand orchestration to any subagent |
| Merge glossary candidates into `docs/glossary/` | `git commit` / `git add` / modify `.claude/` |
| Write `docs/README.md` + glossary L0 + state file | — |

## Output directory hard constraint

Everything goes under `<project_root>/docs/` (**plural**, at the **project root**): flow docs in `docs/flows/`, glossary in `docs/glossary/`, the state file at `docs/.docgen-state.json`, the top index at `docs/README.md`. Directory `CLAUDE.md` files are the one exception—they are written **next to the source directory they describe** (e.g. `internal/workers/CLAUDE.md`), because Claude Code auto-loads them from there.

---

## Self-test mode (`--selftest`)

When `$ARGUMENTS` contains `--selftest`, do NOT run the normal workflow. Instead:

1. Resolve `project_root` (Step B). Create the scratch dir **plus a selftest marker**:
   ```bash
   rm -rf "<project_root>/docs/.docgen-scratch"
   mkdir -p "<project_root>/docs/.docgen-scratch/run/agents" \
            "<project_root>/docs/.docgen-scratch/run/gate" \
            "<project_root>/docs/.docgen-scratch/run/selftest"
   ```
2. Spawn ONE minimal `docgen-flow` Task whose prompt instructs it to simply `Write` a one-line file to `docs/flows/_selftest.md` (content: `selftest ok`) and return `DONE`—no real analysis. This causes SubagentStart, one PreToolUse(Write), and SubagentStop to fire, each dumping its raw input under `selftest/`.
3. Read every `docs/.docgen-scratch/run/selftest/*.json`. For each event, check whether it carries `agent_id`, `subagent_type`, `cwd`, `tool_input.file_path`.
4. Print a report (English), e.g.:
   ```
   /docgen --selftest results
     SubagentStart : agent_id=<yes|no>  subagent_type=<yes|no>  cwd=<yes|no>
     PreToolUse    : agent_id=<yes|no>  tool_name=<yes|no>  tool_input.file_path=<yes|no>
     SubagentStop  : agent_id=<yes|no>

   Assumption 1 (SubagentStart has agent_id): <PASS|FAIL>
   Assumption 2 (PreToolUse has agent_id):    <PASS|FAIL>
   → PreToolUse guard currently runs the <per-subagent | degraded global-whitelist> path.
   ```
5. Clean up: `rm -rf "<project_root>/docs/.docgen-scratch"` and remove `docs/flows/_selftest.md`. Exit.

This is isolated from normal runs: it only writes the selftest marker, and the hook dump bypass is inert unless `selftest/` exists.

---

## Workflow (execute step by step; do not skip)

### Step A: Parse `$ARGUMENTS`

```
internal/workers --concurrency=4
pkg/auth --entry='POST /api/v1/login'        # override auto-discovery
src --lang=en-US --max-depth=8
.                                            # whole repo
```

Rules:
- First non-`--` token is `path` (required).
- `--entry=<glob or symbol or "METHOD /route">` may repeat; **its presence disables auto-discovery** (you document only the user's entries; see Step E.1 and §13.7 TODO-G).
- `--max-depth=N` DFS depth cap, **default 6**.
- `--profile=<name>` selects a specific entry-discovery profile from `entry-profiles/` (default: auto-select every profile whose `file_glob` matches; falls back to `generic`).
- `--include=` / `--exclude=` repeat & accumulate. `include` defaults to `["*.go"]`; `exclude` defaults to `["*_test.go", "**/vendor/**", "**/.git/**"]`.
- `--concurrency=N` default 8.
- `--lang=<CODE>` optional (Step A.1).
- `--no-glossary` boolean: skip glossary extraction/merge.
- `--no-review` boolean: skip the adversarial review loop (default: review **on**).
- `--max-review-rounds=N`: hard cap on rewrite rounds per flow (**default: unlimited**, guarded by the oscillation check in Step G.3).
- `--no-mermaid` boolean: tell `docgen-flow` to omit the Mermaid diagram (default: **on**).
- `--no-callgraph` boolean: disable the gopls call-graph provider; every hop uses grep heuristics only (use for non-Go repos or when gopls is unavailable). Default: provider **on**.
- `--no-shared` boolean: disable pre-extraction of shared hotspot nodes; every flow walks its full chain (more tokens, simpler). Default: shared extraction **on** (requires callgraph; auto-off if `--no-callgraph`).
- `--shared-threshold=N` fan-in threshold for treating a node as a shared hotspot. Default 3.
- `--force` boolean: ignore all incremental logic; regenerate everything.
- `--selftest` boolean: diagnostic mode—verify what fields the hooks actually receive on this Claude Code build, then exit. Does NOT run normal documentation generation. See "Self-test mode" below.

If `path` is empty, fail loudly:
```
❌ Missing <path>. Usage: /docgen <path> [--entry=...] [--max-depth=N] [--include=...] [--exclude=...] [--concurrency=N] [--lang=CODE] [--no-glossary] [--no-review] [--max-review-rounds=N] [--no-mermaid] [--no-callgraph] [--no-shared] [--shared-threshold=N] [--force]
```

### Step A.1: Resolve output language (`lang`)

`raw_lang` by priority (first hit wins): `--lang=` → `$DOCGEN_LANG` (`printenv DOCGEN_LANG`) → `state.config.lang` (if state exists) → default `zh-CN`. Then normalize:

| Input (case-insensitive) | → |
|---|---|
| `zh` / `中文` / `简体中文` / `chinese` / `cn` / `zh-cn` | `zh-CN` |
| `zh-tw` / `繁体` / `繁體中文` / `traditional` | `zh-TW` |
| `en` / `english` / `英文` / `英语` / `en-us` | `en-US` |
| `ja` / `jp` / `日文` / `日本語` / `japanese` / `ja-jp` | `ja-JP` |
| `ko` / `韩文` / `한국어` / `korean` / `ko-kr` | `ko-KR` |
| `fr` / `法文` / `french` | `fr-FR` |
| `de` / `德文` / `german` | `de-DE` |
| **anything else** | passed through verbatim (model interprets it) |

Use this single `lang` for the whole run; every subagent gets it.

> ⚠️ Your status/error output to the user is **fixed in English**; `lang` only affects generated documentation content.

### Step B: Locate `project_root`

```bash
test -n "$DOCGEN_PROJECT_ROOT" && echo "$DOCGEN_PROJECT_ROOT"   # 1. env var
git rev-parse --show-toplevel                                   # 2. git root
```
Both fail → `❌ Cannot locate project root. Run inside a git repo, or set $DOCGEN_PROJECT_ROOT.`

### Step C: Expand `path`

```
target_abs = path if absolute else <project_root>/path
test -e <target_abs> || fail and exit
```

### Step C.1: Create the per-run scratch directory (§15.5)

The three hooks share a per-run scratch directory for identity markers and retry counts. **Lifecycle is yours:**

```bash
# 1. On EVERY run start, first wipe ALL stale scratch dirs (backstops leaks from a
#    previous run that died before cleanup—do NOT rely only on end-of-run cleanup):
rm -rf "<project_root>/docs/.docgen-scratch"

# 2. Create this run's dir. No timestamp source is needed—the scratch root was just
#    emptied, so a single fixed subdir name is unique within it:
mkdir -p "<project_root>/docs/.docgen-scratch/run/agents" "<project_root>/docs/.docgen-scratch/run/gate"
```

- The hooks detect "in a docgen run" by the **existence of a subdirectory** under `docs/.docgen-scratch/`. Creating it here is what arms the PreToolUse guard; wiping it at the end (Step L) is what disarms it.
- Ensure `docs/.docgen-scratch/` is git-ignored (it holds volatile state). If a `.gitignore` exists at the project root and doesn't already ignore it, you may append a line; otherwise note it in the final report.
- **Retry counts are not durable resume state**: a resumed run starts fresh scratch, so SubagentStop retry counters reset to 0—consistent with "a flow is an atomic unit, no mid-flight checkpoint" (§13.1).

### Step D: Read / initialize state (v3)

```bash
test -f <project_root>/docs/.docgen-state.json && echo EXISTS || echo FIRST_RUN
```

**v3 schema (authoritative)**:

```json
{
  "version": 3,
  "last_run": "<ISO>",
  "last_run_sha": "<git rev-parse HEAD at last run>",
  "config": { "project_root": "...", "include": ["*.go"], "exclude": [],
              "lang": "zh-CN", "max_depth": 6 },
  "entries": [
    { "kind": "http_route|rpc_method|main|exported_iface|cron|consumer",
      "signature": "...", "file": "...", "symbol": "...", "slug": "<flow-slug>" }
  ],
  "flows": {
    "<flow-slug>": {
      "entry": { "kind": "...", "signature": "...", "file": "...", "symbol": "..." },
      "lang": "zh-CN",
      "status": "pending | in_progress | flow_done | review_passed | review_unconverged | orphaned",
      "attempts": 1,
      "flow_doc_path": "docs/flows/<slug>.md",
      "touched_files": { "<rel path>": "<sha256>" },
      "review": { "status": "passed | failed_unconverged", "rounds": 0, "last_issues": [] },
      "generated_at": "..."
    }
  },
  "directories": {
    "<dir>": { "lang": "...", "status": "done", "claude_md_path": ".../CLAUDE.md",
               "flows_through": ["<slug>"], "uncovered_files": ["..."], "generated_at": "..." }
  },
  "file_to_flows": { "<rel path>": ["<slug>"] },
  "dir_to_flows":  { "<dir>": ["<slug>"] },
  "shared_to_flows": { "<shared-slug>": ["<business-flow-slug>"] },
  "coverage": { "candidates_total": 0, "touched": 0, "uncovered": ["<rel path>"] },
  "glossary": { "terms_count": 0, "l0_path": "docs/glossary/GLOSSARY.md", "generated_at": "..." }
}
```

- **Terminal statuses** (skippable on resume): `review_passed`, `review_unconverged`, `orphaned`. Everything else (`pending` / `in_progress` / `flow_done`) re-runs whole.
- **FIRST_RUN**: init in memory `{ "version":3, "flows":{}, "directories":{}, "entries":[], "file_to_flows":{}, "dir_to_flows":{}, "coverage":{}, "glossary":{}, "config":{...}, "last_run":null, "last_run_sha":null }`.
- **EXISTS**: Read & parse. **If `version < 3`** (old v1/v2 per-file state): the architecture changed from per-file to flow-centric—the old `files` map is not convertible. Tell the user: `⚠️ State is v<N> (per-file). The flow-centric architecture needs a rebuild; re-run with --force to regenerate.` Then either proceed as `--force` (if they passed it) or stop. Do **not** try to migrate `files` into `flows`.
- Parse failure → `❌ state.json unparseable; pass --force or delete <path> and rerun.`

### Step E: Scan candidate files (the coverage universe)

For `target_abs`, iterate every `include` pattern, Glob `"<target_abs>/**/<pat>"`, merge & dedupe, then drop anything matching any `exclude` pattern (Glob has no exclude—filter in Bash/in-memory). Result: `candidates_all` (relative to `project_root`).

Empty → tell the user "no matching code files under the target" and return. This set is the denominator of the coverage ledger.

### Step E.1: Discover entry points (heuristic + `--entry`)

Entry points are where execution begins. Discover them so each becomes one flow.

**If `--entry` was passed**: use exactly those (resolve each glob/symbol/route to a concrete `file` + `symbol` via grep). **Skip auto-discovery entirely** (§13.7 TODO-G). If an `--entry` can't be resolved, log an info line and skip it.

**Otherwise auto-discover via entry profiles** (rules live in `${CLAUDE_PLUGIN_ROOT}/entry-profiles/*.json`, not hardcoded here):

1. Load every `entry-profiles/*.json`. Each has `{ name, lang, file_glob, entry_patterns:[{kind,grep}], false_positive_filters:[...] }`.
2. Select applicable profiles: those whose `file_glob` matches files in `candidates_all`. If `--profile=<name>` was passed, use only that profile. If none match, fall back to `generic.json`.
3. For each selected profile, run each `entry_patterns[].grep` via `grep -nE` over `candidates_all`; each hit is a candidate entry of that `kind`.
4. **False-positive filtering (mandatory):** drop any hit matching any of the profile's `false_positive_filters` (test files, comment lines, vendor/generated/mock). **Log one info line per filtered hit** so misses are auditable.

Profiles are data: adding a language/framework means adding a JSON file, not editing this command. See `entry-profiles/README.md`.

**Empty entry set is not silent:** if discovery (or `--entry` resolution) yields nothing →
```
❌ No entry points found. Pass --entry='<METHOD /route>' or --entry='<Symbol>' to specify them explicitly.
```
and exit.

**Assign a stable `flow-slug` to each entry** (filename + state key; must be globally unique):
- HTTP route → `<method>_<path>` (e.g. `post_api_v1_login`); RPC/method → `<pkg>_<struct>_<method>`; main/cron/consumer → `<pkg>_<symbol>`. Normalize illegal filename chars (`/`→`_`, strip leading `/`, lowercase).
- **Collision fallback**: if two entries normalize to the same slug, append `_2`, `_3`, … and persist the chosen slug in `entries[].slug` so incremental re-runs recompute the *same* slug from the entry fields (no slug drift).

### Step F: Decide the work set (which flows to (re)generate)

**FIRST_RUN or `--force`**: every discovered entry → a flow in the work set.

**Incremental** (state exists, no `--force`)—follow §13.3:

**F.1 Compute `changed_files`** (basis: last run's commit):
```bash
git -C <root> diff --name-only <last_run_sha> HEAD 2>/dev/null   # commits since last run
git -C <root> diff --name-only HEAD              2>/dev/null     # uncommitted tracked
git -C <root> ls-files --others --exclude-standard 2>/dev/null   # untracked
```
Merge & dedupe. If `last_run_sha` is missing/invalid (e.g. rebased) → degrade to full (all flows).

**F.2 Dirty-flow propagation** via `file_to_flows`: for each `f ∈ changed_files`, every slug in `file_to_flows[f]` is **stale → regenerate whole** (review state voided). Second-confirm with the comment-stripped sha256 (git says changed but content-equivalent → skip). **Deleted-file edge**: before hashing, check existence—if a flow's `touched_files` entry no longer exists on disk, **treat as changed and regenerate that flow**; do not sha256 a missing path. Log info `file X deleted, regenerating flow Y`.

**F.3 Entry add/remove** (always re-discover unless `--entry` given): compare discovered entries to `state.entries`. **New entry → new flow.** **Vanished entry → orphan handling (Step K.3)**, do not regenerate.

**F.4 Lang mismatch**: any flow whose `state.flows[slug].lang ≠ this run's lang` → regenerate.

Flows already in a terminal status and not flagged by F.2–F.4 are **skipped** (trusted).

**F.5 Refresh the coverage ledger** (even in incremental—or you'll misreport): re-enumerate `candidates_all`, set `coverage.uncovered = candidates_all − ⋃ all flows' touched_files`. New files touched by no flow land in `uncovered` and are listed in the final report.

### Step F.6: Discover shared hotspot nodes (skip if `--no-shared` or `--no-callgraph`)

Reused nodes (auth middleware, common repos) get walked/reviewed once instead of once per flow.

1. **Build fan-in via the provider**: for each entry, do a bounded-depth (≤ `max_depth`) outgoing traversal with the call-graph provider, accumulating a fan-in count per callee symbol (how many distinct entries' chains reach it). gopls is incremental, so accumulate during traversal—there is no whole-graph snapshot.
2. **Select hotspots**: symbols with `fan-in ≥ --shared-threshold` (default 3), EXCLUDING ① the entries themselves (too shallow) and ② pure leaves with no substantial subchain (nothing to factor out).
3. **Spawn a shared `docgen-flow` per hotspot** with `mode: shared`, output `docs/flows/_shared/<slug>.md` (slug = `_shared/` + normalized `pkg.Symbol`). Each goes through the same review sub-loop (Step G.3). Record as a flow in state with the status machine identical to business flows.
4. **Feed hotspots to business flows**: pass each Step G `docgen-flow` a `shared_nodes: [{symbol, doc_path}]` list; it stops descending at those nodes and links instead.

**State (v3) addition**: `shared_to_flows: { "<shared-slug>": ["<business-flow-slug>", ...] }`—which business flows reference each hotspot. Rebuild each run from business flows' shared-node hits.

**Incremental**: a `_shared/<slug>.md` is a flow—same dirty-propagation (its touched files change → regenerate). A business flow re-runs only when its own chain changes OR a referenced hotspot's `doc_path` changes (rare; content changes alone don't move `doc_path`, so referencing flows need not re-run).

### Step G: Run each flow as an independent generate→review→rewrite pipeline

> ★ Hotspot. The blocks below are the **real `Task` parameters you must emit**, not pseudocode. The known failure is treating "I should spawn" as a thought—**actually invoke `Task`.**

**Concurrency model (§10.3):** start up to `--concurrency` `docgen-flow` Tasks in parallel. **The moment a flow returns `flow_done`, it enters its own review sub-loop immediately**—do not wait for other flows. Generation and review/rewrite share the same `--concurrency` budget. Each flow's state machine advances independently (`in_progress → flow_done → review_passed/unconverged`); write state to disk as each flow reaches a terminal status (resume depends on it).

**G.1 Spawn `docgen-flow`** (for each flow in the work set, in parallel batches ≤ concurrency, **all in one message per batch**):

```
Task(
  subagent_type: "docgen-flow",
  description: "<e.g. 'flow: POST /api/v1/login'>",
  prompt: """
You are docgen-flow. Generate the end-to-end flow document for the entry below.

project_root: <absolute>
lang: <normalized lang>
max_depth: <N>
mermaid: <true|false>          # false iff --no-mermaid
callgraph: <true|false>        # false iff --no-callgraph
mode: business
shared_nodes:
  - symbol: <pkg.Symbol>          # from Step F.6; omit this block entirely if --no-shared
    doc_path: docs/flows/_shared/<slug>.md
entry:
  kind: <http_route|rpc_method|main|exported_iface|cron|consumer>
  signature: <e.g. "POST /api/v1/login">
  file: <entry source file, relative to project_root>
  symbol: <entry function/method name>
flow_doc_path: docs/flows/<slug>.md
flow_doc_path_abs: <project_root>/docs/flows/<slug>.md

Return DONE / PARTIAL / FAILED per your protocol (with touched_files + sha256 + glossary_candidates).
"""
)
```
Set `model: "opus"` for entries you expect to fan out widely (many touched files). Pass only concrete paths, never globs.

**G.2 On return → update state**:
- `DONE`/`PARTIAL` (doc written) → `flows[slug] = { ..., status: "flow_done", touched_files: {<from return, with sha256>}, attempts: prev+1, generated_at }`, stash `glossary_candidates`. Proceed to G.3.
- `FAILED` → `attempts = prev+1`. If `< 2`, requeue. If `== 2`, `status` stays non-terminal but write a `.FAILED.md` placeholder (replace trailing `.md` → `.FAILED.md`, absolute path, content = reason + "delete attempts from state or rerun --force") and stop retrying this flow.

**G.3 Review sub-loop** (skip entirely if `--no-review`; then treat `flow_done` as terminal `review_passed` with `review.status:"passed", rounds:0`):

```
Task(
  subagent_type: "docgen-flow-review",
  description: "<e.g. 'review: post_api_v1_login'>",
  prompt: """
You are docgen-flow-review. Independently re-read the source and verify the flow doc's call chain.

project_root: <absolute>
flow_doc_path_abs: <project_root>/docs/flows/<slug>.md
touched_files:
  - <rel path 1>
  - <rel path 2>
  ...

Return PASS, or FAIL with issues (each issue MUST carry file:line evidence).
"""
)
```

- **PASS** → `flows[slug].status = "review_passed"`, `review = { status:"passed", rounds:<r> }`. Back-fill the doc header (Step K.1). Terminal. Write state.
- **FAIL** → **discard any issue lacking `file:line` evidence** (§10.2). If no valid issues remain → treat as PASS. Otherwise re-spawn `docgen-flow` with the same params **plus** `review_issues:` (the valid issues verbatim) telling it to fix exactly those hops without inventing new edges; on its return go back to G.3 (review again). Increment `review.rounds`.
- **Convergence guard (§10.6)**: rounds are uncapped by default, BUT if two consecutive review rounds return **substantially the same `issues`** (nothing fixed) → stop: oscillation. Also stop if `--max-review-rounds=N` is hit. Either way → `status = "review_unconverged"`, `review.status = "failed_unconverged"`, keep the last doc, write the unconverged banner (Step K.2). Terminal.

**Per-flow self-check** (immediately after each dispatch): Did I *actually* invoke `Task`, or just plan to? How many did I send this batch (== batch size)? Is each return one of the protocol words?

### Step H: Build directory processing order

After all flows reach a terminal status, aggregate the reverse indexes from every flow's `touched_files`:
- `file_to_flows[f] = [slugs touching f]`
- `dir_to_flows[dir] = [slugs touching any file in dir]` (dir = each ancestor directory of each touched file, within `target_abs`).

The set of directories to document = keys of `dir_to_flows` (plus, in incremental mode, only those touched by regenerated/new/orphaned flows—§13.3 Step 4). Process **deepest first** (leaf directories before parents) and **serially** (a parent CLAUDE.md links children; parallel would create dead-link windows).

### Step I: Write each directory's CLAUDE.md (spawn `docgen-dir`)

For each directory `D` (deepest first), **actually** invoke:

```
Task(
  subagent_type: "docgen-dir",
  description: "<CLAUDE.md: D>",
  prompt: """
You are docgen-dir. Write/update the context-guide CLAUDE.md for the directory below.
ONLY touch content inside the <!-- BEGIN/END docgen:auto --> markers; never overwrite human content.

project_root: <absolute>
lang: <normalized lang>
dir_path: <D relative to project_root>
claude_md_path: <D>/CLAUDE.md
claude_md_path_abs: <project_root>/<D>/CLAUDE.md

flows_through:
  - slug: <slug>
    title: <flow title>
    doc: docs/flows/<slug>.md
    doc_rel_from_dir: <relative path from <D>/CLAUDE.md to the flow doc>
    review_status: <passed|unconverged|orphaned>
key_files:
  - path: <file in D touched by a flow>
    touched_by: [<slug>...]
uncovered_files:
  - <file in D not touched by any flow>
glossary_terms:
  - term: <term>
    slug: <slug>
    rel: <relative path from <D>/CLAUDE.md to docs/glossary/terms/<slug>.md>
parent_dir:
  source: <parent dir>
  claude_md: <parent dir>/CLAUDE.md

Return DONE / FAILED per protocol.
"""
)
```

On `DONE` → `directories[D] = { lang, status:"done", claude_md_path, flows_through, uncovered_files, generated_at }`. If the return has `oversize:true`, log a warn line (§4.3 budget). Write state. **Cross-directory serial**: D's `docgen-dir` must return before the next directory's dispatch.

### Step J: Merge the glossary (skip if `--no-glossary`) — §12

Layout: `docs/glossary/GLOSSARY.md` (L0 index) + `docs/glossary/terms/<slug>.md` (L1 detail, one term per file). Both use `<!-- BEGIN/END docgen:auto -->` sentinels so human edits outside survive.

Merge all flows' `glossary_candidates`, keyed by normalized-lowercase `term`:
- **New term** → create `terms/<slug>.md` (slug = the term itself; for Chinese terms the term is a fine filename, or ASCII-ize if needed) with the L1 auto block: definition, code anchor, "appears in flows" links, source. Add one line to L0.
- **Existing term** → add the new flow to that L1's "appears in flows" (inside its auto block); do not overwrite a human-polished definition outside the block.
- **Rebuild L0** from every L1's head: `- [term](./terms/<slug>.md) — <one-line> （别名：…）`. Keep L0 < 200 lines (paginate by category if it grows past that). Use **plain markdown links, never `@import`** (imports load eagerly and defeat progressive disclosure).
- Update `state.glossary = { terms_count, l0_path:"docs/glossary/GLOSSARY.md", generated_at }`.
- **Orphan-term residue (§13.7 TODO-F)**: if a term's only "appears in flows" were orphaned flows, **leave it and mark stale—do not delete** (consistent with orphan-flow handling).

L0 skeleton (zh-CN):
````markdown
# 术语索引

> 由 `/docgen` 自动维护 ｜ 共 N 条 ｜ 最近更新 <ISO>
> 详情见 `terms/` 下对应文件（本索引不展开详情）

<!-- BEGIN docgen:auto -->
- [回源](./terms/回源.md) — 缓存未命中时向源站拉取内容（别名：origin pull）
<!-- END docgen:auto -->
````

### Step K: Banners and orphans (main-thread-only header patches)

The flow-doc metadata header `review` field and all banners are written **only by you** (subagents never touch them—§11.2).

**K.1 Review-status back-fill**: after a flow's review sub-loop ends, patch the header line of `docs/flows/<slug>.md` (the `> ... 校验：⏳ 待校验 ...` line): `review_passed → ✅ 通过`; `review_unconverged → ⚠️ 存疑（N 轮未收敛）` (localized by `lang`). Use `Edit` on that one line.

**K.2 Unconverged banner (§10.4)**: for `review_unconverged` flows, insert at the top of the doc (after the title) a localized banner listing the reviewer's still-open issues:
```markdown
> ⚠️ **本流程文档未通过校验** ｜ 校验轮次：<N> ｜ 生成于 <ISO>
> reviewer 仍存疑的点（请以源码为准）：
> - <hop>: <problem>
```

**K.3 Orphan flow (§13.4)**: an entry that vanished this run → **do not delete** the doc; set `status:"orphaned"` and insert a localized banner:
```markdown
> ⚠️ **本流程对应的入口已不存在** ｜ 上次见于 <last_run_sha> ｜ 标记于 <ISO>
> 该流程可能已废弃或入口被重命名/重构，内容可能过期，请以源码为准。
```
If the entry reappears in a later run, clear the orphan mark and regenerate.

### Step L: Top-level index, cleanup, final report

**L.1 Write `docs/README.md`** (you write it; do not spawn an agent). Sections (titles switch by `lang`; paths kept verbatim):
- **Flow list** — two sub-sections: **Business flows** (`docs/flows/*.md`) and **Shared nodes** (`docs/flows/_shared/*.md`), each with review status.
- **Directory tree** — link each directory's `CLAUDE.md`.
- **Glossary entry** — link `docs/glossary/GLOSSARY.md` (omit if `--no-glossary`).
- **Uncovered files** — list `coverage.uncovered` explicitly (honesty over false completeness).

**L.2 Finalize state**: set `last_run`, `last_run_sha = git rev-parse HEAD`, `config` (incl. `lang`, `max_depth`), `coverage` counts. Write `docs/.docgen-state.json`.

**L.3 Clean up scratch**: `rm -rf "<project_root>/docs/.docgen-scratch"` (disarms the hooks). Safe to remove unconditionally—it's volatile.

**L.4 Final self-check** (hard assertions; failure → report the run as failed, do not paper over):
```
assert Task(docgen-flow) calls made           == number of flows in the work set   (≥1 if work set > 0)
assert Task(docgen-flow, mode=shared) calls == number of hotspots discovered   (0 if --no-shared)
assert Task(docgen-flow-review) calls made     >= number of flows reviewed          (unless --no-review)
assert Task(docgen-dir) calls made             == number of directories processed
assert every .md you Write-d directly ⊆ { docs/README.md, docs/glossary/** }
       and every CLAUDE.md you Edit-ed touched only inside docgen:auto markers
```
> ⚠️ If `Task(docgen-flow) == 0` while the work set > 0—you never actually spawned. **Report failure**; don't write flow docs yourself.

**L.5 Success report** (English):
```
✅ /docgen completed

  Target:            <target_path>
  Output language:   <lang>
  Entry points:      <N>
  Flows generated:   <done>
  ✓ Review passed:   <P>
  ⚠️ Review unconverged: <U>
  ⊘ Orphaned flows:  <O>
  ✗ Permanent fail:  <F>
  ⊝ Skipped (unchanged): <S>
  Directories (CLAUDE.md): <M>
  Glossary terms:    <T>            (omitted if --no-glossary)
  Coverage:          <touched>/<candidates_total> files touched
  Uncovered files:   <K>  (listed in docs/README.md)
  Elapsed:           <sec> s

  Flows:       <project_root>/docs/flows/
  Glossary:    <project_root>/docs/glossary/GLOSSARY.md
  State file:  <project_root>/docs/.docgen-state.json
  Top index:   <project_root>/docs/README.md
```

---

## Common mistakes (cautionary tales)

> Quoted lines are **past failure modes**, NOT instructions.

- ❌ "git diff returned nothing → work set empty → DONE." On FIRST_RUN diff is empty too, but state is empty, so **every entry enters the work set**.
- ❌ "I'm going to spawn the flow Tasks…" then stops. **Actually invoke `Task`**—spawning = a real tool call.
- ❌ "All flows generated → DONE." You still owe the review sub-loops, the directory CLAUDE.md files, the glossary, the banners, and the top index.
- ❌ Overwriting a hand-written `CLAUDE.md`. The subagent only edits inside `docgen:auto` markers; verify your inputs don't ask it to do otherwise.
- ❌ Reading source and writing flow docs yourself. You are the scheduler—`docgen-flow` reads source; you never do.
- ❌ Forgetting to wipe `docs/.docgen-scratch` at the end—leaves the PreToolUse guard armed for the user's later unrelated work (the next run's Step C.1 wipe also covers this, but clean up anyway).

## Hard constraints

1. **Actually invoke `Task`** for `docgen-flow` / `docgen-flow-review` / `docgen-dir`.
2. **Write state after each flow reaches a terminal status and after each directory completes** (resume depends on it).
3. **Per-flow pipelines run in parallel** up to `--concurrency`; **directories are serial, deepest first**.
4. **Review rounds are uncapped by default** but stop on oscillation or `--max-review-rounds`.
5. **Discard reviewer issues without `file:line` evidence.**
6. **Do not delete orphan flow docs or unconverged docs**—banner them.
7. **Refresh the coverage ledger every run**, including incremental.
8. **Wipe `docs/.docgen-scratch` at start (all stale) and end (this run).**
9. **Do not `git commit` / `git add`; do not modify `.claude/` or source code.**
10. **Generated content follows `lang`; your status/error output is English.**

## Bash command list (whitelist these in settings before first use)

```bash
git -C <root> rev-parse HEAD ; git -C <root> rev-parse --show-toplevel
git -C <root> diff --name-only <sha> HEAD ; git -C <root> diff --name-only HEAD
git -C <root> ls-files --others --exclude-standard
grep -nE '<entry patterns>' <files>            # entry discovery
wc -l <file> ; test -f <file>
sed -E -e 's|//.*$||' -e ':a;N;$!ba;s|/\*[^*]*\*+([^/*][^*]*\*+)*/||g' <file> | tr -s '[:space:]' ' ' | sha256sum | awk '{print $1}'
mkdir -p <dir> ; rm -rf <project_root>/docs/.docgen-scratch
printenv DOCGEN_LANG ; printenv DOCGEN_PROJECT_ROOT
command -v gopls               # call-graph provider probe (degrades to grep if absent)
```

## Failure backstops

- state.json unparseable → fail to user; suggest `--force` or deleting state.
- Old v1/v2 state → tell the user to `--force` (no auto-migration to flow model).
- All git commands fail → degrade to full mode (all entries → work set).
- A `Task` errors → bump `attempts`, follow the retry path.
- A `Write` fails → terminate the run but keep saved state intact.
- Entry discovery empty → fail loudly asking for `--entry=`.

## Example invocations

```
/docgen internal/service
/docgen pkg/auth --entry='POST /api/v1/login'
/docgen . --max-depth=8 --concurrency=4
/docgen . --no-review --no-glossary            # fast structural pass
/docgen src --lang=en-US
/docgen pkg/auth --force
/docgen lua/ --include='*.lua' --entry='handler.entry'
/docgen lua/ --include='*.lua' --profile=generic
```
