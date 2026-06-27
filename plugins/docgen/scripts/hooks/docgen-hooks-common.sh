#!/usr/bin/env bash
# docgen-hooks-common.sh —— shared helpers for the three docgen hooks
# (SubagentStart / PreToolUse / SubagentStop). Pure shell, zero tokens.
#
# 关键设计点（why）：
#  - 三个 hook 都需要「当前是否正处于一次 /docgen run 中」这个前置开关，
#    以及一个 per-run scratch 目录来跨 hook 传递身份标记与重试计数（见计划 §15.5）。
#  - PreToolUse 对全会话每次 Write/Edit/Bash 都触发，所以「不在 run 中就立即放行」
#    是本护栏成立的硬前提——绝不能对用户无关写操作一刀切。
#
# 约定：scratch 目录位于 <project_root>/docs/.docgen-scratch/ ，由编排器在 run
# 启动时创建本次 run 的子目录、收尾时清理；每次 run 启动还会先清陈旧目录兜底泄漏。

set -u

# 读取 hook 输入（stdin 上的一段 JSON），缓存到变量供各脚本复用。
docgen_read_input() {
  DOCGEN_HOOK_INPUT="$(cat 2>/dev/null || true)"
}

# 用 jq 取字段；jq 不存在或取不到时回退到 grep/sed 粗解析，再不行返回空。
# 入参：$1 = jq 过滤表达式（如 '.tool_name'）；$2 = 粗解析用的 JSON key 名（可选）。
docgen_json() {
  local filter="$1" key="${2:-}"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$DOCGEN_HOOK_INPUT" | jq -r "$filter // empty" 2>/dev/null
    return
  fi
  # 回退：仅支持顶层简单字符串字段的粗提取
  if [ -n "$key" ]; then
    printf '%s' "$DOCGEN_HOOK_INPUT" \
      | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
      | head -n1
  fi
}

# 定位 project_root：优先环境变量，其次从 cwd 向上找 git 根。
# 与编排器（commands/docgen.md Step B）保持同一套解析口径。
docgen_project_root() {
  if [ -n "${DOCGEN_PROJECT_ROOT:-}" ] && [ -d "${DOCGEN_PROJECT_ROOT}" ]; then
    printf '%s' "$DOCGEN_PROJECT_ROOT"
    return 0
  fi
  local cwd
  cwd="$(docgen_json '.cwd' 'cwd')"
  [ -z "$cwd" ] && cwd="$PWD"
  git -C "$cwd" rev-parse --show-toplevel 2>/dev/null && return 0
  # 再兜底：从 cwd 向上找含 docs/.docgen-scratch 的目录
  local d="$cwd"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    if [ -d "$d/docs/.docgen-scratch" ]; then
      printf '%s' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  return 1
}

# scratch 根目录路径（不保证存在）。
docgen_scratch_root() {
  local root
  root="$(docgen_project_root)" || return 1
  printf '%s/docs/.docgen-scratch' "$root"
}

# 返回「当前正在进行的 run」的 scratch 子目录：取 scratch 根下最新修改的子目录。
# 不存在任何子目录 → 视为「不在 run 中」，返回非零。
docgen_active_run_dir() {
  local sroot
  sroot="$(docgen_scratch_root)" || return 1
  [ -d "$sroot" ] || return 1
  local latest=""
  latest="$(ls -1dt "$sroot"/*/ 2>/dev/null | head -n1)"
  [ -z "$latest" ] && return 1
  printf '%s' "${latest%/}"
}

# 是否正处于一次 docgen run 中（前置开关）。
docgen_in_run() {
  docgen_active_run_dir >/dev/null 2>&1
}

# 当前 run 的 done 标记目录（不保证存在）。无 run 返回非零。
# done/<slug>.done 由 SubagentStop(docgen-flow) 在校验放行时写入，
# 供主线程收尾对账「哪些流程其实已生成完」（设计 §三）。
docgen_done_dir() {
  local rd; rd="$(docgen_active_run_dir)" || return 1
  printf '%s/done' "$rd"
}

# 当前 run 的 review 进度目录（不保证存在）。无 run 返回非零。
# review/<slug>.json 由 SubagentStop(docgen-flow-review) 写入，记 rounds/裁决/未解 issue（设计 §四）。
docgen_review_dir() {
  local rd; rd="$(docgen_active_run_dir)" || return 1
  printf '%s/review' "$rd"
}

# 从流程文档路径提取 slug。
# 入参 $1：docs/flows/<slug>.md 或 docs/flows/_shared/<slug>.md（可为绝对路径）。
# 共享节点（_shared/ 子目录）归一为 _shared__<name>，避免子目录分隔符进 done/review 文件名。
# 失败（不匹配 flows 路径）返回非零。
docgen_slug_from_flow_path() {
  local p="$1" tail
  case "$p" in
    *docs/flows/_shared/*) tail="${p##*docs/flows/_shared/}"; printf '_shared__%s' "${tail%.md}"; return 0 ;;
    *docs/flows/*)         tail="${p##*docs/flows/}";         printf '%s' "${tail%.md}";          return 0 ;;
    *) return 1 ;;
  esac
}

# 输出一段 JSON 到 stdout（hook 协议的标准回传方式）。
docgen_emit() {
  printf '%s\n' "$1"
}

# selftest 旁路：仅当本次 run 的 scratch 下存在 selftest/ 标记目录时，
# 把本次原始 hook 输入 dump 一份，供 --selftest 验证 hook 输入字段（计划 D8）。
# 入参：$1 = 事件名（subagent_start | pretooluse | subagent_stop）。
# 关键设计点：正常 run 下 selftest/ 不存在，本函数立即返回，零副作用。
docgen_selftest_dump() {
  local event="$1"
  local run_dir
  run_dir="$(docgen_active_run_dir 2>/dev/null)" || return 0
  [ -d "$run_dir/selftest" ] || return 0
  local out="$run_dir/selftest/${event}.json"
  # 多次触发同事件时追加序号，避免覆盖
  local i=1
  while [ -e "$out" ]; do out="$run_dir/selftest/${event}.${i}.json"; i=$((i+1)); done
  printf '%s' "$DOCGEN_HOOK_INPUT" > "$out" 2>/dev/null || true
}
