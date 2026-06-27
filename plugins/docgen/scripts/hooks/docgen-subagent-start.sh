#!/usr/bin/env bash
# docgen-subagent-start.sh —— SubagentStart hook (§15.1)
#
# 用途：在每个 docgen 子代理启动入口，确定性注入该子代理的共享约束
#       （additionalContext，本事件仅支持加上下文、不支持 block，正合适）。
# 收益：① 约束每次 spawn 都注入（含 review 打回后的每次重写），不会漂移；
#       ② 规则集中一处维护，子代理文件与编排 prompt 都瘦身；③ 零 token、不可被跳过。
#
# matcher 由 hooks.json 锁定为具体 subagent type，事件层面就只对该子代理触发，
# 故脚本内可直接按 subagent_type 选注入内容。
#
# 身份标记（配合 PreToolUse §15.2）：若 hook 输入带 agent_id，则把
# 「agent_id → subagent_type」写进本次 run 的 scratch 目录，供 PreToolUse 归因。
# 这是计划标注的「待验证假设」——拿不到 agent_id 时此步静默跳过，PreToolUse 自有降级路径。

set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=docgen-hooks-common.sh
. "$HOOK_DIR/docgen-hooks-common.sh"

docgen_read_input

SUBAGENT_TYPE="$(docgen_json '.subagent_type' 'subagent_type')"
AGENT_ID="$(docgen_json '.agent_id' 'agent_id')"

# 写身份标记（假设成立时才有 agent_id）
if [ -n "$AGENT_ID" ]; then
  RUN_DIR="$(docgen_active_run_dir || true)"
  if [ -n "$RUN_DIR" ]; then
    mkdir -p "$RUN_DIR/agents" 2>/dev/null || true
    printf '%s' "$SUBAGENT_TYPE" > "$RUN_DIR/agents/$AGENT_ID.type" 2>/dev/null || true
  fi
fi

# 按子代理类型选注入文案。内容是「再叮嘱一遍铁律」，与各 agent 文件互为冗余加固。
case "$SUBAGENT_TYPE" in
  docgen-flow)
    CTX='docgen-flow 铁律（hook 注入）：1) 产物章节须齐全（TL;DR / 入口与触发 / 调用链总览 / 逐层解析 / 数据流转 / 外部依赖与副作用 / 错误与分支路径 / 改动风险 / 触达文件清单，断点章节按需）；2) 调用链每一跳必须带来源标注三选一（直接调用 / 推断:接口→实现 / ⚠️未能跟进:<形式>）；3) 严禁凭符号名臆测调用边——跟不下去就标断点 + grep 候选，绝不编造；4) 每跳内联代码 ≤20 行，超出标「… (+N 行)」；5) 元信息头 review 字段首版写「⏳ 待校验」，不要自填「✅ 通过」；6) 只写 docs/flows/ 下的目标文件。'
    ;;
  docgen-dir)
    CTX='docgen-dir 铁律（hook 注入）：1) 产出 CLAUDE.md 为「上下文指引」而非索引——只写指针、链到 docs/flows 与 docs/glossary，不内联调用链/代码/流程正文；2) 保护既有文件：只改 <!-- BEGIN/END docgen:auto --> 之间内容，无该区块则追加到文件末尾，绝不整文件覆盖；3) 自动区块 ≤200 行；4) 不读整源文件/整流程文档，仅头部 + 轻量 grep。'
    ;;
  docgen-flow-review)
    CTX='docgen-flow-review 铁律（hook 注入）：1) 你只裁决、不写任何文档（无 Write，亦不得用 Bash 重定向写文件）；2) 独立重新读源码核对，不信任流程文档结论；3) 偏向拒绝：查不到证据支持的跳判 FAIL；4) 每条 FAIL issue 必须附源码证据 file:line，否则无效；5) 只查事实（每跳是否真实存在 / 内联片段是否一致 / 来源标注是否诚实 / Mermaid 边是否真实），不查可读性与完整性。'
    ;;
  *)
    # 非 docgen 子代理：理论上 matcher 不会让它进来；保险起见直接放行不注入。
    exit 0
    ;;
esac

# 以 additionalContext 形式回传（hook JSON 协议）。jq 不在时手工拼最简 JSON。
if command -v jq >/dev/null 2>&1; then
  docgen_emit "$(jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"SubagentStart", additionalContext:$c}}')"
else
  # 手工转义双引号与反斜杠
  esc=$(printf '%s' "$CTX" | sed 's/\\/\\\\/g; s/"/\\"/g')
  docgen_emit "{\"hookSpecificOutput\":{\"hookEventName\":\"SubagentStart\",\"additionalContext\":\"$esc\"}}"
fi
exit 0
