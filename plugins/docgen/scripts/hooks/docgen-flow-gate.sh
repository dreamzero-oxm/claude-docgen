#!/usr/bin/env bash
# docgen-flow-gate.sh —— SubagentStop hook，matcher 锁定 docgen-flow（§14）
#
# 用途：把「机械/确定性/最常见的低级错」左移到 docgen-flow 子代理出口，
#       在结果回主线程、触发昂贵的 LLM reviewer 之前就纠正，减少「生成→review FAIL→重写」往返。
#       本 hook 不做语义判断（A 是否真的调 B），那归 docgen-flow-review（LLM，主线程）。
#
# matcher 在 hooks.json 写 "docgen-flow"，事件层面只对该子代理触发，脚本不必再自筛类型。
#
# 机械校验项（任一不达标即 block，把清单回传 reason 让子代理自己补）：
#  1) 输出文件存在且非空；
#  2) §11 固定章节标题齐全；
#  3) 每一跳都带来源标注三选一；
#  4) 文件:行 引用校验——仅校验文档内出现的引用，逐条核对文件存在、行号 ≤ 总行数；
#     引用条数设上限（默认 200），超出只抽样，避免触达文件极多时超时；
#  5) 内联代码块 ≤20 行，或带「… (+N 行)」截断标记。
#
# 防死循环：SubagentStop 无内建轮次计数，脚本按 agent_id 在 scratch 目录自管，
#           命中上限（默认 3）即不再 block、放行，交主线程 reviewer + 存疑 banner 兜底。

set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=docgen-hooks-common.sh
. "$HOOK_DIR/docgen-hooks-common.sh"

docgen_read_input
docgen_selftest_dump "subagent_stop"

PROJECT_ROOT="$(docgen_project_root || true)"
AGENT_ID="$(docgen_json '.agent_id' 'agent_id')"
RUN_DIR="$(docgen_active_run_dir || true)"

MAX_RETRY="${DOCGEN_FLOW_GATE_MAX_RETRY:-3}"
REF_LIMIT="${DOCGEN_FLOW_GATE_REF_LIMIT:-200}"

# block 回传：要求该子代理继续修，把不达标清单塞进 reason。
block() {
  local reason="$1"
  if command -v jq >/dev/null 2>&1; then
    docgen_emit "$(jq -n --arg r "$reason" '{decision:"block", reason:$r}')"
  else
    esc=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')
    docgen_emit "{\"decision\":\"block\",\"reason\":\"$esc\"}"
  fi
  exit 0
}

pass() { exit 0; }

# —— 轮次计数（防死循环）——
retry_count=0
retry_file=""
if [ -n "$RUN_DIR" ] && [ -n "$AGENT_ID" ]; then
  mkdir -p "$RUN_DIR/gate" 2>/dev/null || true
  retry_file="$RUN_DIR/gate/$AGENT_ID.retries"
  [ -f "$retry_file" ] && retry_count="$(cat "$retry_file" 2>/dev/null || echo 0)"
fi

# 定位本次产出的 flow 文档：扫 hook 输入里对 docs/flows/*.md 的 Write。
FLOW_DOC=""
if command -v jq >/dev/null 2>&1; then
  FLOW_DOC="$(printf '%s' "$DOCGEN_HOOK_INPUT" \
    | jq -r '[.. | objects | (.file_path? // empty)] | map(select(test("docs/flows/.*\\.md$"))) | last // empty' 2>/dev/null)"
fi
if [ -z "$FLOW_DOC" ]; then
  # 回退：从整段输入里 grep 一个 docs/flows/*.md 路径
  FLOW_DOC="$(printf '%s' "$DOCGEN_HOOK_INPUT" | grep -oE '/[^"]*docs/flows/[^"]*\.md' | tail -n1)"
fi

# 把候选项补成绝对路径
if [ -n "$FLOW_DOC" ] && [ "${FLOW_DOC#/}" = "$FLOW_DOC" ] && [ -n "$PROJECT_ROOT" ]; then
  FLOW_DOC="$PROJECT_ROOT/$FLOW_DOC"
fi

# 计数自增并落盘（无论后续 block 或 pass，本次都算一轮校验）
if [ -n "$retry_file" ]; then
  printf '%s' "$((retry_count + 1))" > "$retry_file" 2>/dev/null || true
fi

# 命中重试上限 → 不再 block，放行兜底
if [ "$retry_count" -ge "$MAX_RETRY" ]; then
  pass
fi

# 校验 1：找到了文件且非空
if [ -z "$FLOW_DOC" ]; then
  block "未检测到对 docs/flows/*.md 的写入：docgen-flow 必须实际 Write 出流程文档。请确认已写文件后重试。"
fi
if [ ! -s "$FLOW_DOC" ]; then
  block "流程文档不存在或为空：$FLOW_DOC 。请生成完整内容后写入。"
fi

issues=""

# 校验 2：固定章节标题齐全（按语义关键词匹配，兼容多语言标题中至少含这些标志词之一）。
# 用「任一语言关键词命中即视为存在」的宽松匹配，避免对非中文 lang 误报。
need_section() {
  # $1 = 描述；$2... = 任一命中即视为存在的关键词
  local desc="$1"; shift
  local pat
  pat="$(printf '%s|' "$@")"; pat="${pat%|}"
  if ! grep -Eq "$pat" "$FLOW_DOC"; then
    issues="${issues}\n- 缺章节：$desc（未匹配到关键词 $pat）"
  fi
}
need_section "TL;DR"            'TL;DR|一句话'
need_section "入口与触发"        '入口与触发|Entry|エントリ|トリガ'
need_section "调用链总览"        '调用链总览|Call-chain|Call chain|呼び出し'
need_section "逐层解析"          '逐层解析|Per-hop|hop analysis|逐層'
need_section "数据流转"          '数据流转|Data flow|データ'
need_section "外部依赖与副作用"   '外部依赖|External dep|外部依存|side effect'
need_section "错误与分支路径"     '错误与分支|Errors|分岐|エラー'
need_section "改动风险"          '改动风险|Change risk|変更リスク'
need_section "触达文件清单"       '触达文件|Touched|タッチ'

# 校验 3：调用链须带来源标注三选一。
# 启发式存在性兜底——若全文一个标注都没有，几乎必是漏写。
if ! grep -Eq "直接调用|inferred|推断|未能跟进|direct call|couldn't follow" "$FLOW_DOC"; then
  issues="${issues}\n- 调用链缺来源标注：每一跳必须带「直接调用 / 推断:接口→实现 / ⚠️未能跟进:<形式>」三选一。"
fi

# 校验 5：内联代码块 ≤20 行，否则须带「… (+N 行)」截断标记。
overlong="$(awk '
  /^```/ {
    if (infence) {
      if (lines > 20 && !trunc) { print NR": "lines" 行未截断" }
      infence=0; lines=0; trunc=0
    } else { infence=1; lines=0; trunc=0 }
    next
  }
  infence {
    lines++
    if ($0 ~ /\(\+[0-9]+ ?行\)|\(\+[0-9]+ ?lines\)|… *\(\+/) trunc=1
  }
' "$FLOW_DOC" 2>/dev/null)"
if [ -n "$overlong" ]; then
  issues="${issues}\n- 内联代码块超 20 行且未截断（应标「… (+N 行)」）：$(printf '%s' "$overlong" | tr '\n' ';')"
fi

# 校验 4：file:行 引用校验（设上限抽样）。
# 校验文档里出现的「<相对路径>:<行号>」引用——逐条核对文件存在、行号 ≤ 总行数。
if [ -n "$PROJECT_ROOT" ]; then
  refs="$(grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+:[0-9]+' "$FLOW_DOC" 2>/dev/null | sort -u | head -n "$REF_LIMIT")"
  bad_refs=""
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    f="${ref%:*}"; ln="${ref##*:}"
    # 跳过明显非源码路径（docs/ 自身、URL、其他 .md）
    case "$f" in docs/*|http*|*.md) continue ;; esac
    abs="$PROJECT_ROOT/$f"
    if [ ! -f "$abs" ]; then
      bad_refs="${bad_refs} ${ref}(文件不存在)"
      continue
    fi
    total="$(wc -l < "$abs" 2>/dev/null | tr -d ' ')"
    if [ -n "$total" ] && [ "$ln" -gt "$((total + 1))" ] 2>/dev/null; then
      bad_refs="${bad_refs} ${ref}(行号>总行数$total)"
    fi
  done <<EOF
$refs
EOF
  if [ -n "$bad_refs" ]; then
    issues="${issues}\n- 引用的 file:行 无效（疑似编造）：${bad_refs}"
  fi
fi

# 汇总：有 issue 就 block，否则放行。
if [ -n "$issues" ]; then
  block "$(printf 'docgen-flow 产物机械校验未通过（第 %s 次，上限 %s），请修正后重试：%b' "$((retry_count + 1))" "$MAX_RETRY" "$issues")"
fi

pass
