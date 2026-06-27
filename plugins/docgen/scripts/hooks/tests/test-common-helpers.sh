#!/usr/bin/env bash
# 验证 common.sh 的 scratch 子目录助手与 slug 提取。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
. "$HERE/../docgen-hooks-common.sh"

# 造一个临时 project_root + 一个 run scratch 子目录
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export DOCGEN_PROJECT_ROOT="$TMP"
mkdir -p "$TMP/docs/.docgen-scratch/run/agents"

RUN_DIR="$(docgen_active_run_dir)"
assert_eq "$RUN_DIR" "$TMP/docs/.docgen-scratch/run" "active_run_dir 定位本次 run"
assert_eq "$(docgen_done_dir)"   "$RUN_DIR/done"   "done_dir 路径"
assert_eq "$(docgen_review_dir)" "$RUN_DIR/review" "review_dir 路径"
assert_eq "$(docgen_slug_from_flow_path 'docs/flows/post_api_v1_login.md')" "post_api_v1_login" "普通流程 slug"
assert_eq "$(docgen_slug_from_flow_path '/abs/docs/flows/_shared/authsvc_login.md')" "_shared__authsvc_login" "共享节点 slug"
assert_done
