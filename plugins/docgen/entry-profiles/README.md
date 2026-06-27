# entry-profiles

`/docgen` 的入口发现规则数据文件。每个框架/语言一个 JSON。

## 字段

| 字段 | 含义 |
|------|------|
| `name` | profile 名，`--profile=<name>` 可显式指定 |
| `lang` | 适用语言（`*` 表示通用兜底） |
| `file_glob` | 适用的源文件通配（编排器据此选用 profile） |
| `entry_patterns` | 入口匹配规则数组，每条 `{kind, grep}`；`grep` 喂给 `grep -nE` |
| `false_positive_filters` | 误报过滤：命中即排除（测试文件/注释行/vendor/生成代码/mock 等） |

## 加入新框架

新增一个 `<framework>.json` 即可，无需改编排逻辑。编排器加载本目录所有 `*.json`，按 `file_glob` 选适用项。
