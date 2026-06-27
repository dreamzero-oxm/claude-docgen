#!/usr/bin/env bash
# 极简 bash 断言助手（测试脚手架）。不引入外部测试框架，零依赖。
set -u
ASSERT_FAILED=0
assert_eq() { # $1=实际 $2=期望 $3=说明
  if [ "$1" = "$2" ]; then printf 'ok   - %s\n' "$3"
  else printf 'FAIL - %s\n      got:  [%s]\n      want: [%s]\n' "$3" "$1" "$2"; ASSERT_FAILED=1; fi
}
assert_file_exists() { # $1=路径 $2=说明
  if [ -s "$1" ]; then printf 'ok   - %s\n' "$2"
  else printf 'FAIL - %s（文件不存在或为空：%s）\n' "$2" "$1"; ASSERT_FAILED=1; fi
}
assert_contains() { # $1=文件 $2=子串 $3=说明
  if grep -qF "$2" "$1" 2>/dev/null; then printf 'ok   - %s\n' "$3"
  else printf 'FAIL - %s（%s 中未找到 [%s]）\n' "$3" "$1" "$2"; ASSERT_FAILED=1; fi
}
assert_done() { exit "$ASSERT_FAILED"; }
