---
name: docgen
description: Use when the user wants to bulk-generate markdown documentation for a code repository, incrementally update an existing docs/ tree, or resume an interrupted run. Multilingual output (Chinese / English / Japanese / Korean / French / German / etc.) is selected via --lang; default is Simplified Chinese. Typical triggers (English & Chinese both work)—"write docs for src/", "generate Chinese docs for this repo", "write Japanese documentation for the project", "帮我给这个目录生成中文文档", "用英文为整个项目写文档", "文档跑断了重新跑", "按文件夹生成 README". Under the hood this delegates to the /docgen slash command plus the docgen-file and docgen-dir subagents for scheduling, per-file documentation, and per-directory MOC generation.
---

# docgen Skill

This skill exposes the `/docgen` slash command to natural-language invocation. **All real work happens via `/docgen`**—this file just translates user intent into the right command call.

## When to use

Trigger this skill when any of the following is true:

- The user explicitly asks to "generate docs / write docs" for some directory or the entire repo (in any language)
- The user mentions wanting their `docs/` populated automatically
- A previous docgen run was interrupted and the user wants to resume
- The user wants to incrementally regenerate based on git changes
- The user wants to force a full regeneration (`--force`)
- The user wants to switch the existing docs to another language

Do **not** use for:

- Ad-hoc explanation of a single file or a code snippet (that's a regular conversation, not a generation task)
- Building an API reference site / Doxygen-style HTML site (out of scope)

## How to use

Forward the request straight to the slash command. **Do not** read source code yourself, **do not** write `.md` files yourself. Hand it off to `/docgen`.

Common invocations:

```
/docgen <path>                                        # default *.go, excludes test/vendor/.git, default zh-CN
/docgen <path> --include='*.go' --include='*.lua'     # multiple includes
/docgen <path> --exclude='**/generated/**'            # add an exclude
/docgen <path> --concurrency=4                        # cap parallelism
/docgen <path> --lang=en-US                           # output in English
/docgen <path> --lang=ja-JP                           # output in Japanese
/docgen <path> --force                                # ignore incremental, regenerate everything
```

### Picking `--lang`

Translate the user's natural-language intent into `--lang=<ISO>`:

| What the user says | What you pass |
|--------------------|---------------|
| "Chinese / Simplified Chinese / 中文 / 用中文 / unspecified" | omit `--lang` (default `zh-CN`) |
| "English / in English / 英文 / 英语" | `--lang=en-US` |
| "Japanese / 日文 / 日语 / 日本語" | `--lang=ja-JP` |
| "Korean / 韩文 / 韩语" | `--lang=ko-KR` |
| "French / 法文" | `--lang=fr-FR` |
| "German / 德文" | `--lang=de-DE` |
| "Traditional Chinese / 繁体 / 繁體中文" | `--lang=zh-TW` |
| anything else | pass the user's term verbatim or its common ISO code; the command does best-effort normalization |

`--lang` also accepts the bilingual aliases above directly (e.g. `--lang=英文`, `--lang=english`); the command normalizes them.

## Conventions

- `<path>` may be relative to the project root (preferred) or absolute
- If the user doesn't specify a path, ask—do **not** default to `.`, repo-wide regeneration is expensive
- If the user is outside a git repo, ask them to `export DOCGEN_PROJECT_ROOT=...` or move into the repo first
- Switching `--lang` on the same project does **not** require `--force`: state.json records each file's `lang`, and mismatched entries regenerate automatically on the next run

## Output

`/docgen` writes everything under `<project_root>/docs/` and maintains `.docgen-state.json` there. Failed files get a `*.FAILED.md` placeholder; the next run auto-retries them. The final report (success / skipped / permanent-failure counts) is delivered in English.

## Notes

- Orchestration logic lives in the `/docgen` slash command's main thread—there is no separate orchestration subagent (Claude Code constraint: subagents cannot spawn other subagents)
- On first use you may see Bash permission prompts. Apply the recommended `settings` snippet from the plugin README to silence them
- `--lang` only affects **generated documentation content**. The orchestration layer's progress / status / error output is fixed in English
