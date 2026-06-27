#!/usr/bin/env bash
# 验证：机械校验全通过时，flow-gate 写出 done/<slug>.done（含 flow_doc 与 touched）。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
GATE="$HERE/../docgen-flow-gate.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export DOCGEN_PROJECT_ROOT="$TMP"
mkdir -p "$TMP/docs/.docgen-scratch/run/agents" "$TMP/docs/flows"

# 造一个被引用的真实源文件（供 file:行 校验通过）
mkdir -p "$TMP/svc"; printf 'package svc\nfunc Login(){}\n' > "$TMP/svc/auth.go"

# 造一份「机械上合格」的流程文档：含全部章节关键词、来源标注、合法 file:行、无超长代码块
DOC="$TMP/docs/flows/post_login.md"
cat > "$DOC" <<'EOF'
# 流程：登录
> 入口 ｜ 校验：⏳ 待校验
## 一、TL;DR
登录。
## 二、入口与触发
HTTP。
## 三、调用链总览
1. Login [直接调用] svc/auth.go:2
## 四、逐层解析
做什么。
## 五、数据流转
映射。
## 六、外部依赖与副作用
DB。
## 七、错误与分支路径
401。
## 九、改动风险
脆弱点。
## 十、触达文件清单
- svc/auth.go:2
EOF

# 合成 SubagentStop(docgen-flow) 的 hook 输入：带对 DOC 的 Write、agent_id、cwd
INPUT=$(cat <<EOF
{"agent_id":"a1","subagent_type":"docgen-flow","cwd":"$TMP",
 "tool_calls":[{"tool_name":"Write","tool_input":{"file_path":"$DOC"}}]}
EOF
)

OUT="$(printf '%s' "$INPUT" | bash "$GATE")"
DONE="$TMP/docs/.docgen-scratch/run/done/post_login.done"
assert_file_exists "$DONE" "校验通过应写 done 标记"
assert_contains "$DONE" "flow_doc=docs/flows/post_login.md" "done 含相对 flow_doc 路径"
assert_contains "$DONE" "touched=" "done 含 touched 行"
assert_contains "$DONE" "svc/auth.go" "done 的 touched 含触达文件"

# 反例：缺章节的文档应 block，且不写 done
BADDOC="$TMP/docs/flows/bad.md"; printf '# 残缺\n## 一、TL;DR\nx\n' > "$BADDOC"
BADIN=$(printf '{"agent_id":"a2","subagent_type":"docgen-flow","cwd":"%s","tool_calls":[{"tool_name":"Write","tool_input":{"file_path":"%s"}}]}' "$TMP" "$BADDOC")
printf '%s' "$BADIN" | bash "$GATE" >/dev/null
if [ -e "$TMP/docs/.docgen-scratch/run/done/bad.done" ]; then
  printf 'FAIL - block 路径不应写 done\n'; ASSERT_FAILED=1
else printf 'ok   - block 路径不写 done\n'; fi
assert_done
