---
description: Multi-agent code documentation generator (default zh-CN, can target en-US / ja-JP / etc.); incremental updates with resume support
argument-hint: <path> [--include=GLOB] [--exclude=GLOB] [--concurrency=N] [--lang=CODE] [--force]
allowed-tools: Read, Grep, Bash, Write
model: claude-sonnet-4-6
---

# /docgen —— bulk code documentation via slash-command self-orchestration

## Architectural premise (read this first)

**You (the conversation running `/docgen`) ARE the orchestrator.** A slash command runs in the **main conversation thread**, so you can call the `Task` (a.k.a. `Agent`) tool to spawn one layer of subagents. The flow:

```
user → /docgen (you, main thread) ──Task──► N × docgen-file (leaf subagents, in parallel)
                                  ──Task──► 1 × docgen-dir  (leaf subagent)
                                  ── you write top-level docs/README.md yourself
```

**MUST NOT** delegate orchestration to any subagent. This is a hard Claude Code architectural limit (per the official docs at `https://code.claude.com/docs/en/sub-agents`):

> "Subagents cannot spawn other subagents."

A subagent cannot in turn spawn its own subagents. So orchestration must stay at the slash-command layer (main thread, not a subagent), which directly issues `Task` calls for `docgen-file` / `docgen-dir`.

## Your hard responsibilities (do not cross the line)

| You **MUST** do | You **MUST NOT** do |
|-----------------|---------------------|
| Parse args, locate `project_root` | Read full source code from the analyzed directory |
| Scan candidates, compute sha256, decide incremental work | Write per-file `.md` docs yourself |
| Slice work units / batch them / serialize across directories | Write any directory's `README.md` MOC yourself |
| Actually invoke `Task` for `docgen-file` / `docgen-dir` | Hand orchestration off to any subagent |
| Maintain `<project_root>/docs/.docgen-state.json` | `git commit` / `git add` / modify `.claude/` config |
| Write the top-level `<project_root>/docs/README.md` | Write any other `.md` (other than the two above) |

## Self-check table (must hold before you return DONE; otherwise fail loudly)

| Metric | Expected | Meaning |
|--------|----------|---------|
| Number of `Task(subagent_type=docgen-file)` calls you **actually** made this run | ≥ number of work units derived from `work_set` | Each work unit gets at least one Task |
| Number of `Task(subagent_type=docgen-dir)` calls you **actually** made this run | == number of directories processed | One MOC per directory |
| Paths you wrote with `Write` directly | Exactly one: `<project_root>/docs/README.md` | No `.md` writes other than the top index |
| Times you `Edit`-ed `state.json` | ≥ (directories processed) + (one per file batch) | Continuous write-back throughout the run |

> ⚠️ **If at the end `Task(docgen-file) == 0` while `work_set > 0`**—you **never actually spawned**; you treated "I should spawn" as a thought and moved on. **Report failure to the user**; do not return success and do not paper over it by writing the MOC yourself.

## Output directory hard constraint

All generated docs **must** be written under `<project_root>/docs/` (the `docs` folder—**plural**—at the **project root**, NOT under cwd, NOT under the analyzed code directory, NOT the singular `doc/`).

Example: with `project_root=/repo/myapp` and analyzed path `internal/workers`, the doc path must be `/repo/myapp/docs/internal/workers/worker_base.go.md`—**not** `/repo/myapp/internal/workers/docs/...`, **not** `<cwd>/docs/...`. The mirrored source path always starts from `project_root`.

---

## Workflow (execute step by step; do not skip steps)

### Step A: Parse `$ARGUMENTS`

`$ARGUMENTS` looks like:

```
internal/workers --concurrency=4
pkg/auth --include='*.go' --exclude='**/vendor/**'
src --lang=en-US                                     # output in English
src --lang=英文                                      # alias works too
.                                                    # the whole repo
```

Rules:
- The first non-`--`-prefixed token is `path` (required)
- `--include=` / `--exclude=` may repeat and accumulate
- `--concurrency=N` defaults to 8
- `--lang=<CODE>` optional; values and default resolution see Step A.1
- `--force` is a boolean flag (presence = true)
- `include` defaults to `["*.go"]`, `exclude` defaults to `["*_test.go", "**/vendor/**", "**/.git/**"]`

If `path` is empty, fail loudly to the user:

```
❌ Missing <path> argument. Usage: /docgen <path> [--include=...] [--exclude=...] [--concurrency=N] [--lang=CODE] [--force]
```

### Step A.1: Resolve output language (`lang`)

Pick a `raw_lang` by priority (first hit wins):

```
1. CLI arg --lang=<value>
2. Env var $DOCGEN_LANG       # printenv DOCGEN_LANG; empty string = unset
3. state.json.config.lang     # only if a state file exists; legacy v1 state has no such field, skip
4. Built-in default "zh-CN"
```

Then normalize `raw_lang` (lowercase, trim whitespace, look up the table below):

| Input (any of these, case-insensitive) | Normalized to |
|----------------------------------------|---------------|
| `zh` / `中文` / `简体中文` / `chinese` / `cn` / `zh-cn` | `zh-CN` |
| `zh-tw` / `繁体` / `繁體中文` / `traditional` / `traditional-chinese` | `zh-TW` |
| `en` / `english` / `英文` / `英语` / `en-us` | `en-US` |
| `ja` / `jp` / `日文` / `日本語` / `japanese` / `ja-jp` | `ja-JP` |
| `ko` / `韩文` / `한국어` / `korean` / `ko-kr` | `ko-KR` |
| `fr` / `français` / `法文` / `french` | `fr-FR` |
| `de` / `deutsch` / `德文` / `german` | `de-DE` |
| **anything else** | passed through verbatim; the model interprets it (e.g. `pt-BR`, `Spanish`, `русский`) |

Result: `lang` (normalized). **Use this single value for the entire run**; every spawned `docgen-file` / `docgen-dir` receives the same `lang`.

> ⚠️ The orchestration layer (your status reports and error messages to the user) is **fixed in English** and does NOT follow `--lang`. `lang` only affects **generated documentation content**.

### Step B: Locate `project_root`

By priority:

```bash
# 1. Environment variable
test -n "$DOCGEN_PROJECT_ROOT" && echo "$DOCGEN_PROJECT_ROOT"

# 2. Walk up to find .git
git rev-parse --show-toplevel
```

If both fail, fail loudly:

```
❌ Cannot locate project root. Run /docgen inside a git repository, or set $DOCGEN_PROJECT_ROOT.
```

### Step C: Expand `path` to an absolute path

```
if path is absolute: target_abs = path
else:                target_abs = <project_root>/path

if not test -e <target_abs>: fail and exit
```

### Step D: Read / initialize state

```bash
test -f <project_root>/docs/.docgen-state.json && echo "EXISTS" || echo "FIRST_RUN"
```

**state schema (v2, includes `lang` field)**:

```json
{
  "version": 2,
  "files": {
    "<source-relative-path>": {
      "sha256": "...",
      "lang": "zh-CN",
      "status": "done | failed_permanent",
      "attempts": 1,
      "doc_path": "docs/...",
      "doc_path_failed": "docs/....FAILED.md",
      "generated_at": "..."
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
    "exclude": ["*_test.go", "**/vendor/**", "**/.git/**"],
    "lang": "zh-CN"
  },
  "last_run": "..."
}
```

**FIRST_RUN**: initialize in memory:

```json
{ "version": 2, "files": {}, "directories": {}, "config": { "lang": "<this run's lang>", ... }, "last_run": null }
```

**EXISTS**: `Read` the file, parse JSON.

> **v1 → v2 auto-migration**: if `state.version` is missing or `< 2`:
> - set `state.version` to `2`
> - backfill `"lang": "zh-CN"` on every `state.files[*]` entry that lacks it
> - backfill `"lang": "zh-CN"` on every `state.directories[*]` entry that lacks it
> - default `state.config.lang` to `"zh-CN"` (legacy versions could only emit Chinese)
> - On the first run after upgrade, state migrates automatically—no manual step required

> **On FIRST_RUN, state has no file records**—this is normal. **Every candidate file should be processed**; do not skip.

### Step E: Scan candidate files

For `target_abs`, **iterate the `include` array from Step A** and Glob each pattern; merge & dedupe to `candidates_raw`:

```
for pat in include:
    Glob: "<target_abs>/**/<pat>"          # e.g. pat="*.go" → "<target_abs>/**/*.go"
merge all results → candidates_raw
```

> ⚠️ Do not hardcode `*.go`. Users may pass `--include='*.lua'` or `--include='*.py' --include='*.go'`; iterate every pattern in the array.

Then filter out anything matching any `exclude` pattern (`*_test.go`, `**/vendor/**`, `**/.git/**`, etc. The Glob tool has no exclude support—use Bash `[[ ... = pattern ]]` or in-memory fnmatch). Result: `candidates_all`.

If `candidates_all` is empty → tell the user "no matching code files under the target directory" and return.

### Step F: Decide `work_set` (files to process)

**FIRST_RUN (state.files empty) or `force=true`**:
```
work_set = candidates_all     # process everything
```

**Incremental (state.files non-empty, force=false)**:

First, get a git-eyes view of changed files to narrow the sha256-compute set:

```bash
# Run all three; merge & dedupe → git_changed
git -C <project_root> diff --name-only HEAD~1 HEAD 2>/dev/null
git -C <project_root> diff --name-only HEAD       2>/dev/null
git -C <project_root> ls-files --others --exclude-standard 2>/dev/null
```

For each `f ∈ candidates_all`, **decide in this order** (first hit wins):

1. `f` not in `state.files` → **work_set** (new file)
2. `f` in `state.files` but `status != done` → **work_set** (last run didn't finish it)
3. `f` in `state.files`, `status == done`:
   - `state.files[f].lang` ≠ this run's `lang` → **work_set** (lang mismatch—doc must regenerate)
   - **not in `git_changed`** → `skipped` (trust git; **do not** compute sha256)
   - **in `git_changed`** → compute sha256: matches state → `skipped`; differs → **work_set**

> 99% of files don't need sha256; only files git reports as changed do. A language switch (`zh-CN` ↔ `en-US`) triggers a regeneration sweep, but only for entries whose lang doesn't match this run; entries from other languages remain undisturbed.

**Compute sha256 (with comments/whitespace stripped)**—only for the 3.b sub-branch:

```bash
sed -E -e 's|//.*$||' -e ':a;N;$!ba;s|/\*[^*]*\*+([^/*][^*]*\*+)*/||g' <file> \
  | tr -s '[:space:]' ' ' \
  | sha256sum | awk '{print $1}'
```

> **Note**: sha256 is computed on the **source file path** (not `doc_path`). The hash is used both to decide `skipped` for this run and as input to docgen-file (which writes it back to state).

### Step G: Dynamic granularity bucketing

For each file in `work_set`:

```bash
wc -l <file>     # line count
wc -c <file>     # byte count
```

| Bucket | Predicate |
|--------|-----------|
| small | lines < 200 AND bytes < 8192 |
| mid   | 200 ≤ lines ≤ 800 |
| large | lines > 800 OR bytes > 40960 |

### Step H: Build processing order (leaf directories first)

Group `work_set` by directory depth and **process the deepest directories first** (a parent's MOC must wait for its children's MOCs to link correctly). Directories at the same depth are siblings.

### Step I: Process one directory (the core loop)

For each directory `D`, do the following:

#### I.1 Slice the directory's `work_set` files into "work units"

- Pack `small` files into `merged_small` units (≤ 5 files each, total ≤ 30KB)
- Each `mid` file becomes its own unit
- Each `large` file becomes its own unit (use `model: "opus"` when invoking the Task)

#### I.2 Batch by `concurrency=N`

Each batch ≤ N work units.

#### I.3 ★ Spawn a batch of `docgen-file` IMMEDIATELY (**do not narrate—just invoke `Task`**)

> This is a known failure hotspot. **What follows is NOT pseudocode and NOT illustrative—it's the real `Task` parameters you must emit.** Treat it like a fill-in-the-blank and send it now.

For **every work unit in the current batch**, in **the same message**, in **parallel**, issue one `Task` call:

```
Task(
  subagent_type: "docgen-file",
  description: "<short, e.g. 'docgen workers/worker_base.go'>",
  prompt: """
You are docgen-file. Follow your workflow to generate documentation for the files below.

context:
  project_root: <absolute project_root>
  lang: <normalized lang from Step A.1, e.g. zh-CN / en-US / ja-JP>
  batch_kind: "single"              # or "merged_small"
  files:
    - path: <source path relative to project_root>
      size_bucket: <small | mid | large>
      doc_path: <doc output path relative to project_root, with .md suffix>
      doc_path_abs: <absolute path = project_root joined with doc_path>
      sha256: <pre-computed 64-char hex>

When done, return DONE / PARTIAL / FAILED per protocol.
"""
)
```

Key points:

- For merged-small units, set `batch_kind: "merged_small"` and list 2–5 files; each entry needs `path / size_bucket / doc_path / doc_path_abs / sha256`
- For `large` units (`size_bucket: large`), **also** pass `model: "opus"` to Task
- Every unit in the batch **must be sent in a single message** (so Claude Code parallelizes them); do not send them serially one by one
- **Do not** put glob patterns (`*.go` etc.) in the prompt—pass only **already-Glob-expanded absolute paths**, to avoid `*` being eaten in cross-process serialization

After dispatching, **stay silent until all Tasks return**; do not write prose while waiting.

**Per-batch self-check (ask yourself immediately after dispatch)**:

1. Did I **actually** invoke the Task tool, or did I just "plan to" in thought? If you didn't really emit it, **stop now and re-emit**—do not move on
2. How many Tasks did I send in this batch? Should equal the unit count for this batch
3. Is each Task's return one of `DONE` / `PARTIAL` / `FAILED`? Anything else counts as `FAILED` for retry purposes

#### I.4 Parse each Task's return → update state

- Returned `DONE`: `state.files[path] = { sha256, lang: <this run's lang>, status: "done", attempts: 1, doc_path, generated_at }`
- Returned `PARTIAL`: handle each file's status individually; entries marked done also get `lang: <this run's lang>` written
- Returned `FAILED`: record `prev = state.files[path]?.attempts ?? 0`; write `state.files[path].attempts = prev + 1`. If `prev + 1 < 2`, requeue for the next batch's retry. If `prev + 1 == 2`, set `status = "failed_permanent"` and **write a placeholder file**:

  - Path rule: replace the trailing `.md` of `doc_path` with `.FAILED.md` (**replace, do not append**). E.g. `docs/.../worker_x.go.md` → `docs/.../worker_x.go.FAILED.md`
  - Use `Write`, with the **absolute path** = `<project_root>/<the relative path above>`
  - Content: failure reason + retry guidance ("delete the entry's `attempts` from state, or re-run with `--force`")
  - **Also record `doc_path_failed` on `state.files[path]`** so docgen-dir can reference the right filename when listing

**Edit `state.json` immediately at end of every batch.** Do not buffer until end-of-directory.

#### I.5 After every batch in this directory finishes: **actually** invoke `Task` for `docgen-dir`

> Same rule as above: this **is not pseudocode**—it's the real `Task` parameters. Skip this step = no MOC for the directory = broken index.

```
Task(
  subagent_type: "docgen-dir",
  description: "<MOC: relative dir path>",
  prompt: """
You are docgen-dir. Write the MOC (README.md) for the directory below.

context:
  project_root: <absolute>
  lang: <normalized lang from Step A.1>
  dir_path: <code dir path relative to project_root>
  moc_path: <README.md path relative to project_root>
  moc_path_abs: <absolute path = project_root joined with moc_path>

children:
  files:
    - source: <relative>
      doc:    <relative, the .md already written>
      doc_abs: <absolute>
      status: done | failed_permanent
    # ...list every file in this directory
  subdirs:
    - source: <relative>
      moc:    <relative>
      moc_abs: <absolute>
    # ...list subdirectories if any
parent_dir:
  source: <relative>
  moc:    <relative>

When done, return DONE / FAILED per protocol.
"""
)
```

**Per-directory self-check**:

1. Did I **actually** invoke `Task(docgen-file)` for this directory? If not, **do not dispatch this**—a step upstream was missed; go back to I.3 and finish it
2. Did I **actually** invoke `Task(docgen-dir)`, or did I just plan to mentally? If not, **send it now**

On `docgen-dir` returning `DONE` → update `state.directories[dir_path] = { lang: <this run's lang>, status: "done", moc_path, generated_at, child_files, child_subdirs }`, then immediately Edit-write state.json.

### Step J: Loop to the next directory

Return to Step I for the next directory.

> **Cross-directory serialization**: a directory's `docgen-dir` MUST return DONE before the next directory's I.3 begins. Reason: a parent MOC must link to its children's MOCs; running them in parallel would create dead-link windows. Within a directory, ≤ N parallel `docgen-file` Tasks per batch is allowed and expected.

### Step K: Write the top-level `docs/README.md` index (you write it; do not spawn an agent)

Once all directories are done, read state to get the full directory list, build a nested directory tree, and `Write` it to `<project_root>/docs/README.md`.

**Title, subtitle, and section names switch by `lang`** (the **directory tree itself is not translated**—it contains file paths, kept verbatim):

| Element | zh-CN | en-US | ja-JP | other lang |
|---------|-------|-------|-------|-----------|
| Main title | `# 项目代码文档索引` | `# Project Code Documentation Index` | `# プロジェクトコード文書インデックス` | translate the zh-CN meaning idiomatically |
| Subtitle (generator) | `由 /docgen 自动生成 ｜ 最近更新：<ISO>` | `Generated by /docgen ｜ Last updated: <ISO>` | `/docgen により自動生成 ｜ 最終更新: <ISO>` | same |
| Subtitle (stats) | `共 N 个文件文档 ｜ M 个目录 MOC` | `N file docs ｜ M directory MOCs` | `ファイル文書 N 件 ｜ ディレクトリ MOC M 件` | same |
| Section 1 | `## 目录树` | `## Directory Tree` | `## ディレクトリツリー` | same |
| Section 2 | `## 全部目录 MOC 索引` | `## All Directory MOCs` | `## 全ディレクトリ MOC` | same |

Template (the outer block uses 4 backticks to avoid the inner directory-tree code block closing prematurely; the example below shows zh-CN; for other langs swap per the table above):

````markdown
# 项目代码文档索引

> 由 `/docgen` 自动生成 ｜ 最近更新：<ISO timestamp>
> 共 N 个文件文档 ｜ M 个目录 MOC

## 目录树

```
internal/
├── workers/    ← [MOC](./internal/workers/README.md)
│   ├── [worker_base.go](./internal/workers/worker_base.go.md)
│   └── ...
└── ...
```

## 全部目录 MOC 索引

- [internal/workers/](./internal/workers/README.md)
- ...
````

### Step L: Final self-check + report to user

**Final self-check (hard assertions; failure → tell the user the run failed)**:

```
assert spawned_file_agents > 0  if work_set > 0
assert spawned_dir_agents == number of directories processed
assert paths you Write-d (.md) ⊆ { <project_root>/docs/README.md }
```

If any assertion fails → report to the user:

```
❌ /docgen internal state inconsistent
  reason: <never_spawned_file_agents | missing_dir_moc | self_wrote_file_doc>
  spawned_file_agents: <N>
  spawned_dir_agents: <N>
  work_set: <N>

Please file an issue with the maintainer; do not treat the current docs/ as a valid result.
```

If all assertions pass, emit the success report:

```
✅ /docgen completed

  Target:           <target_path>
  Output language:  <lang>
  Candidates:       <total_candidates>
  Work set:         <work_set>
  ✓ Done:           <done>
  ✗ Permanent fail: <failed_permanent>
  ⊝ Skipped (hash unchanged): <skipped>
  Elapsed:          <duration_seconds> s

  State file:       <project_root>/docs/.docgen-state.json
  Top-level index:  <project_root>/docs/README.md

Notes:
  - Permanently failed files have .FAILED.md placeholders; the next /docgen run retries them by default
  - Incremental logic active: unchanged files are skipped; pass --force for a full regeneration
```

---

## Common mistakes (cautionary tales)

> The quoted lines below are **examples of past failure modes**—they are NOT what you should do. Each anti-pattern is followed by what to do instead.

### ❌ Mistake 1: skipping the Step F fallback

> "git diff returned nothing, so work_set is empty—DONE."

**Correct**: on FIRST_RUN git diff is also empty, but state is empty too, so **every candidate must enter work_set**.

### ❌ Mistake 2: narrating the spawn instead of spawning

> "I'm going to spawn 14 docgen-file Tasks for the files under workers/..." and then stops.

**Correct**: **actually invoke the Task tool**. In Claude Code, "spawn" = a real `Task` call with full parameters.

### ❌ Mistake 3: forgetting docgen-dir

> "All 14 files are done—DONE."

**Correct**: you also need to spawn one `docgen-dir` to write that directory's `README.md` MOC; only then is the directory complete.

### ❌ Mistake 4: not updating state

> Never writes state.json during the run.

**Correct**: Edit state.json after every docgen-file batch completes; also after each docgen-dir completes. This is what makes interruptions recoverable.

### ❌ Mistake 5: reading source and writing docs yourself

> Directly Read source code and Write `*.go.md` from the orchestrator.

**Correct**: you are the scheduler; **never read the full source content**. Reading source and writing per-file docs is `docgen-file`'s job.

---

## Hard constraints

1. **MUST actually invoke the Task tool** to spawn child agents (`subagent_type: docgen-file` / `docgen-dir`)
2. **Edit state.json immediately after every batch / every directory completes**
3. **Cross-directory serial**, within-directory parallel up to `concurrency` (one batch of N Tasks at a time)
4. **Retries happen at most once per file within a single run**
5. **Do not `git commit` / `git add`**
6. **Do not modify `.claude/` or source code**
7. **The top-level `docs/README.md` is written by you** (do not spawn an agent for it)
8. **Generated documentation content** is emitted in the `lang` from Step A.1 (top-level README headings, the `lang` field passed to subagents). **The orchestration layer (your status / error output to the user) MUST use English**—do not conflate these two

## Bash command list (whitelist these in user / project settings before first use)

> If a Bash permission prompt fires on first use, your `~/.claude/settings.json` or project-local `.claude/settings.local.json` is missing one of these. See the plugin README's "Recommended settings snippet" and merge it in.

```bash
# git changes
git -C <root> diff --name-only HEAD~1 HEAD
git -C <root> diff --name-only HEAD
git -C <root> ls-files --others --exclude-standard

# file size
wc -l <file>; wc -c <file>

# sha256 (with comments/whitespace stripped)
sed -E -e 's|//.*$||' -e ':a;N;$!ba;s|/\*[^*]*\*+([^/*][^*]*\*+)*/||g' <file> \
  | tr -s '[:space:]' ' ' \
  | sha256sum | awk '{print $1}'

# Create directories (subagents handle their own mkdir;
# you may need this only when writing the top-level README.md)
mkdir -p $(dirname <doc_path_abs>)

# Read environment variables (when resolving $DOCGEN_PROJECT_ROOT / $DOCGEN_LANG)
printenv DOCGEN_LANG
printenv DOCGEN_PROJECT_ROOT
```

## Failure backstops

- state.json fails to parse → fail to user; suggest `--force` or manually deleting state and re-running
- All git commands fail → fall back to "full" mode (treat all candidates as work_set)
- A `Task` invocation itself errors → bump `attempts` and follow the retry path
- A `Write` fails → terminate the run, but keep already-saved state intact

## Example invocations

```
/docgen internal/workers
/docgen pkg/auth --concurrency=4
/docgen . --include='*.go' --exclude='**/vendor/**'
/docgen pkg/auth/handler --force
/docgen lua/ --include='*.lua'
/docgen src --lang=en-US                                        # output in English
/docgen src --lang=ja-JP                                        # output in Japanese
/docgen src --lang=英文                                          # alias works → en-US
```
