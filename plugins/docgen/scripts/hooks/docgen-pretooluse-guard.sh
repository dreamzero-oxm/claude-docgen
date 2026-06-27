#!/usr/bin/env bash
# docgen-pretooluse-guard.sh —— PreToolUse hook (§15.2)
#
# 用途：写路径硬护栏。allowed-tools 能限「有没有 Write」，限不住「写到哪」；
#       且 docgen-flow-review 带 Bash，理论上能用重定向绕过「不给 Write」去篡改文档。
#       本 hook 在每次 Write/Edit/Bash 前按归属做路径校验，越界 deny。
#       这是纵深防御的最后一道，轻量、确定性，不替代 allowed-tools。
#
# ⚠️ 硬前提（计划反复强调）：PreToolUse 对整个会话每次工具调用都触发，不限本 plugin。
#    所以脚本第一步必须判「是否正处于一次 docgen run 中」——不在 run 中立即放行，
#    绝不干预用户的任何无关写操作。否则装了 plugin 就会把用户写啥都 deny，是危险设计。
#
# 归因（含待验证假设与降级）：
#  - 若 PreToolUse 输入带 agent_id，且 SubagentStart 已写下身份标记 → 按子代理精细校验；
#  - 拿不到 agent_id / 归因不到 → 降级为「run 内全局写白名单」（仍受前置开关保护）。

set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=docgen-hooks-common.sh
. "$HOOK_DIR/docgen-hooks-common.sh"

docgen_read_input
docgen_selftest_dump "pretooluse"

# —— 前置开关：不在 run 中就立即放行（最重要的一步）——
RUN_DIR="$(docgen_active_run_dir || true)"
if [ -z "$RUN_DIR" ]; then
  exit 0
fi

PROJECT_ROOT="$(docgen_project_root || true)"
[ -z "$PROJECT_ROOT" ] && exit 0   # 连 root 都定不出，不冒险干预

TOOL_NAME="$(docgen_json '.tool_name' 'tool_name')"
AGENT_ID="$(docgen_json '.agent_id' 'agent_id')"

# 提取本次写操作的目标路径 / 命令
FILE_PATH="$(docgen_json '.tool_input.file_path' 'file_path')"
BASH_CMD="$(docgen_json '.tool_input.command' 'command')"

# deny 回传
deny() {
  local reason="$1"
  if command -v jq >/dev/null 2>&1; then
    docgen_emit "$(jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}')"
  else
    esc=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')
    docgen_emit "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$esc\"}}"
  fi
  exit 0
}

# 把绝对/相对路径归一为「相对 project_root」的路径，便于白名单匹配。
rel_of() {
  local p="$1"
  case "$p" in
    "$PROJECT_ROOT"/*) printf '%s' "${p#"$PROJECT_ROOT"/}" ;;
    /*)                 printf '%s' "$p" ;;   # 绝对但不在 root 内 → 原样（多半会被判越界）
    *)                  printf '%s' "$p" ;;   # 相对 → 原样
  esac
}

# run 内全局写白名单：这些相对路径模式允许写。
# flow 文档 / 各目录 CLAUDE.md / 状态文件 / 术语表 / 顶层 README / scratch。
path_allowed() {
  local rel="$1"
  case "$rel" in
    docs/flows/*.md)               return 0 ;;
    */CLAUDE.md|CLAUDE.md)         return 0 ;;
    docs/.docgen-state.json)       return 0 ;;
    docs/glossary/*)               return 0 ;;
    docs/README.md)                return 0 ;;
    docs/.docgen-scratch/*)        return 0 ;;
    *)                             return 1 ;;
  esac
}

# 查身份标记，得到当前子代理类型（可能为空 = 归因不到）。
agent_type_of() {
  [ -z "$AGENT_ID" ] && return 1
  local f="$RUN_DIR/agents/$AGENT_ID.type"
  [ -f "$f" ] || return 1
  cat "$f" 2>/dev/null
}

SUBAGENT_TYPE="$(agent_type_of || true)"

# Bash 写重定向检测：粗匹配 > / >> / tee / sed -i 等明显写盘形式。
bash_has_write() {
  printf '%s' "$BASH_CMD" | grep -Eq '(^|[^>])>>?[[:space:]]*[^&]|[[:space:]]tee([[:space:]]|$)|sed[[:space:]].*-i|dd[[:space:]]|truncate[[:space:]]'
}

# 从 Bash 命令里抽出重定向目标路径（尽力而为，取第一个 > / >> 后的 token）。
bash_redirect_target() {
  printf '%s' "$BASH_CMD" \
    | grep -oE '>>?[[:space:]]*[^ |;&)]+' \
    | head -n1 \
    | sed -E 's/^>>?[[:space:]]*//'
}

case "$TOOL_NAME" in
  Write|Edit|MultiEdit)
    [ -z "$FILE_PATH" ] && exit 0   # 没目标路径，无从校验，放行
    rel="$(rel_of "$FILE_PATH")"

    case "$SUBAGENT_TYPE" in
      docgen-flow)
        case "$rel" in docs/flows/*.md) exit 0 ;; *) deny "docgen-flow 只能写 docs/flows/*.md，拒绝写入：$rel" ;; esac ;;
      docgen-dir)
        case "$rel" in */CLAUDE.md|CLAUDE.md) exit 0 ;; *) deny "docgen-dir 只能写各目录 CLAUDE.md，拒绝写入：$rel" ;; esac ;;
      docgen-flow-review)
        deny "docgen-flow-review 只裁决、禁止任何写操作，拒绝写入：$rel" ;;
      *)
        # 归因不到具体子代理（可能是主线程编排器，或拿不到 agent_id）→ run 内全局白名单
        if path_allowed "$rel"; then exit 0; else deny "docgen run 内写路径越界（白名单外）：$rel"; fi ;;
    esac
    ;;
  Bash)
    # 只在确实是写盘命令时才管；纯读命令（grep/cat/wc/...）一律放行
    bash_has_write || exit 0
    if [ "$SUBAGENT_TYPE" = "docgen-flow-review" ]; then
      deny "docgen-flow-review 禁止任何写操作（含 Bash 重定向/tee/sed -i）"
    fi
    tgt="$(bash_redirect_target)"
    [ -z "$tgt" ] && exit 0           # 抽不出目标，保守放行（仍有 SubagentStop 兜底）
    rel="$(rel_of "$tgt")"
    if path_allowed "$rel"; then exit 0; else deny "docgen run 内 Bash 写重定向路径越界：$rel"; fi
    ;;
  *)
    exit 0 ;;
esac
exit 0
