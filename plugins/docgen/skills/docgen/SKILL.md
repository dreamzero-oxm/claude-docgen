---
name: docgen
description: Use when the user wants to document a code repository by its execution flows / call chains, generate per-directory CLAUDE.md context guides, build a project glossary, incrementally update an existing docs/ tree, or resume an interrupted run. Multilingual output (Chinese / English / Japanese / Korean / French / German / etc.) via --lang; default Simplified Chinese. Typical triggers (English & Chinese)—"write flow docs for src/", "document this service from its entry points", "trace the login API call chain", "梳理登录接口的调用链", "从入口分析这个服务", "按调用链写文档", "帮我给这个目录生成中文文档", "文档跑断了重新跑", "为每个目录生成 CLAUDE.md". Under the hood this delegates to the /docgen slash command plus the docgen-flow, docgen-flow-review and docgen-dir subagents.
---

# docgen Skill

This skill exposes the `/docgen` slash command to natural-language invocation. **All real work happens via `/docgen`**—this file just translates user intent into the right command call.

`/docgen` is **flow-centric**: it discovers entry points (HTTP/RPC routes, `main`/`init`, exported service methods, cron/consumers), walks each one's call chain depth-first into an end-to-end **flow document** (`docs/flows/*.md`), adversarially reviews each flow against the source, writes a **context-guide `CLAUDE.md`** in each touched directory, and maintains a **progressive-disclosure glossary** (`docs/glossary/`). A coverage ledger lists any files no flow touched.

## When to use

Trigger this skill when any of the following is true:

- The user asks to document a repo/directory **by its flows or call chains** ("from the entry points", "trace the request", "按调用链/从入口")
- The user wants their `docs/` populated automatically, or per-directory `CLAUDE.md` guides written
- The user wants a project glossary / terminology index built
- A previous docgen run was interrupted and the user wants to resume
- The user wants an incremental regenerate based on git changes
- The user wants to force a full regeneration (`--force`) or switch the docs to another language

Do **not** use for:

- Ad-hoc explanation of a single file or snippet (that's a regular conversation)
- Building an API reference site / Doxygen-style HTML (out of scope)

## How to use

Forward the request straight to the slash command. **Do not** read source code yourself, **do not** write `.md` / `CLAUDE.md` files yourself. Hand it off to `/docgen`.

Common invocations:

```
/docgen <path>                                   # auto-discover entries, default *.go, zh-CN
/docgen <path> --entry='POST /api/v1/login'      # document only this entry's flow
/docgen <path> --entry='AuthSvc.Login'           # entry by symbol
/docgen <path> --max-depth=8                     # deeper DFS (default 6)
/docgen <path> --include='*.go' --include='*.py' # multiple includes
/docgen <path> --concurrency=4                   # cap parallelism (default 8)
/docgen <path> --no-review                        # skip the adversarial review loop (faster)
/docgen <path> --no-glossary                      # skip glossary extraction
/docgen <path> --no-mermaid                       # text-tree call chains only
/docgen <path> --lang=en-US                       # output in English
/docgen <path> --force                            # ignore incremental, regenerate everything
```

### Picking `--lang`

| What the user says | What you pass |
|--------------------|---------------|
| "Chinese / 中文 / 用中文 / unspecified" | omit `--lang` (default `zh-CN`) |
| "English / 英文 / 英语" | `--lang=en-US` |
| "Japanese / 日文 / 日本語" | `--lang=ja-JP` |
| "Korean / 韩文" | `--lang=ko-KR` |
| "French / 法文" | `--lang=fr-FR` |
| "German / 德文" | `--lang=de-DE` |
| "Traditional Chinese / 繁体" | `--lang=zh-TW` |
| anything else | pass the user's term or its ISO code; the command normalizes |

`--lang` also accepts bilingual aliases directly (e.g. `--lang=英文`, `--lang=english`).

## Conventions

- `<path>` may be relative to the project root (preferred) or absolute
- If the user doesn't specify a path, ask—do **not** default to `.`, repo-wide regeneration is expensive
- If auto-discovery finds no entry points, `/docgen` will ask for `--entry=`; relay that to the user
- If the user is outside a git repo, ask them to `export DOCGEN_PROJECT_ROOT=...` or move into the repo first
- The user's existing hand-written `CLAUDE.md` files are **protected**—docgen only edits inside a `<!-- BEGIN/END docgen:auto -->` block, appending if no block exists
- Switching `--lang` does **not** require `--force`: the state file records each flow's `lang` and regenerates mismatched flows automatically

## Output

`/docgen` writes everything under `<project_root>/docs/` (flow docs in `docs/flows/`, glossary in `docs/glossary/`, top index `docs/README.md`, state in `.docgen-state.json`) plus a `CLAUDE.md` next to each documented source directory. Unconverged or orphaned flows are kept with a ⚠️ banner, not deleted. The final report (passed / unconverged / orphaned / uncovered counts) is delivered in English.

## Notes

- Orchestration (including the review loop) lives in the `/docgen` main thread—there is no orchestration subagent (Claude Code constraint: subagents cannot spawn subagents)
- The plugin registers three deterministic shell hooks (SubagentStart / PreToolUse / SubagentStop) that inject constraints, guard write paths, and mechanically validate flow docs—zero-token, no user action needed
- On first use you may see Bash permission prompts; apply the recommended `settings` snippet from the plugin README to silence them
- `--lang` only affects **generated documentation content**; the orchestration layer's progress/status/error output is fixed in English
