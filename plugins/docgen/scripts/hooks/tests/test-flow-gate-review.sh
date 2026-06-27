#!/usr/bin/env bash
# 验证：subagent_type=docgen-flow-review 时，flow-gate 只记 review 进度、不 block、不机械校验。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
GATE="$HERE/../docgen-flow-gate.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export DOCGEN_PROJECT_ROOT="$TMP"
mkdir -p "$TMP/docs/.docgen-scratch/run/review"

# reviewer 对 post_login 流程返回 FAIL + 两条 issue。约定 reviewer 输出经 hook 输入的
# output 字段透传；脚本应从中解析裁决。
INPUT=$(cat <<'EOF'
{"agent_id":"r1","subagent_type":"docgen-flow-review","cwd":"__TMP__",
 "flow_doc_path":"docs/flows/post_login.md",
 "output":"FAIL\nissues:\n  - hop: 3 / UserRepo.FindByName\n    problem: \"service/auth.go:55 实现体内无对 FindByName 的调用\"\n  - hop: 5 / LogSvc.Write\n    problem: \"内联片段与 service/auth.go:71 不一致\""}
EOF
)
INPUT="${INPUT/__TMP__/$TMP}"

OUT="$(printf '%s' "$INPUT" | bash "$GATE")"
REV="$TMP/docs/.docgen-scratch/run/review/post_login.json"
assert_file_exists "$REV" "reviewer 结束应写 review 进度文件"
assert_contains "$REV" '"last_verdict": "fail"' "记录 FAIL 裁决"
assert_contains "$REV" '"rounds":' "记录轮次字段"
assert_contains "$REV" "FindByName" "保留未解 issue 原文"
# reviewer 分支绝不 block：输出不应含 decision:block
if printf '%s' "$OUT" | grep -q '"decision":"block"'; then
  printf 'FAIL - reviewer 分支不应 block\n'; ASSERT_FAILED=1
else printf 'ok   - reviewer 分支不 block\n'; fi
assert_done
