# docgen 插件架构文档

> 版本：对应 plugin `0.6.0` ｜ 生成于 2026-06-27
> 范围：`plugins/docgen/` 全部组件。本文描述「系统如何运作」，是给维护者的架构参考，不是用法手册（用法见 `README.md`）。

---

## 一、一句话定位

docgen 是一个**以「执行流程」为组织维度**的代码文档生成器。它从入口点出发，深度优先（DFS）沿调用链读源码，为每条入口生成一份端到端的「流程文档」，对每条流程做对抗式事实校验，在每个被触达的目录写一份上下文指引 `CLAUDE.md`，并维护一份渐进式披露的术语表。支持多语言输出、git 增量更新、断线续跑。

**最关键的架构事实：整个插件没有可运行的业务代码。** 它由三类纯文本资产构成：

1. **prompt markdown**：一个 slash 命令（编排器）+ 三个子代理定义；
2. **确定性 shell hook**：三个零 token 的 bash 脚本，在子代理生命周期的固定点触发；
3. **数据文件**：入口发现 profile（JSON）+ 运行期状态文件（JSON）。

「逻辑」是写给 LLM 读的指令；「确定性保证」由 shell hook 兜底。理解这个二分法是理解整份架构的钥匙。

---

## 二、顶层编排模型（为什么编排在主线程）

Claude Code 有一条硬约束：**子代理不能再派生子代理**（`https://code.claude.com/docs/en/sub-agents`）。而 slash 命令运行在**主对话线程**里、可以调用 `Task`（即 Agent）工具派生一层子代理。

由此推出整个系统的形状：**跑 `/docgen` 的那个对话本身就是编排器**。所有调度、review 循环、状态维护都留在主线程；子代理只做「叶子」工作（读源码写文档 / 读源码裁决）。

```
用户 ──/docgen──► 主线程（编排器，commands/docgen.md）
        │  解析参数 / 定位 project_root / 解析 lang
        │  入口发现（entry-profiles + --entry 覆盖）
        │  维护 docs/.docgen-state.json（v3.1）
        │  每条流程跑「生成 → review → 重写」独立流水线（多条并行）
        │  回填流程文档头部校验状态 / banner
        │  合并 glossary（L0 索引 + L1 词条）
        │  写顶层 docs/README.md
        ├──Task──► docgen-flow        × N   （每入口一个：DFS 走链 → 流程文档）
        ├──Task──► docgen-flow-review × ≥N  （独立读源码，对抗式校验调用边真伪）
        └──Task──► docgen-dir         × M   （每目录一个：写 CLAUDE.md 上下文指引）

确定性 hook 层（shell，零 token）：
  SubagentStart(flow/dir/review) ── 入口注入各自铁律
  PreToolUse(Write/Edit/Bash)    ── run 内写路径越界即 deny
  SubagentStop(flow)             ── 出口机械校验产物 + 写 done 标记
  SubagentStop(flow-review)      ── 记录 review 轮次/裁决/未解 issue
```

**组织单元是「流程」**（一个入口点 + 它调用的一切），不是文件。一份轻量「覆盖账本」仍逐文件追踪，确保没有源文件被静默漏掉。

---

## 三、组件分解

### 3.1 编排器 `commands/docgen.md`

主线程的全部职责。它**必须做**：解析参数、定位 root、入口发现、维护状态文件、真正调用 `Task` 跑每条流程的流水线、回填文档头部与 banner、合并 glossary、写 README。它**绝不做**：自己读全量源码写流程文档、自己写任何 `docs/flows/*.md` 或目录 `CLAUDE.md`、把编排权交给子代理、`git commit`。

工作流是固定的 Step A→L（见 §五）。

### 3.2 子代理 `agents/docgen-flow.md`

DFS 调用链分析的核心。输入一个入口（kind/signature/file/symbol），从入口符号开始 grep/Read 定位实现，逐层识别下游调用、DFS 到 `max_depth`（默认 6）或叶子。产物是一份结构固定的流程文档（TL;DR / 入口与触发 / 调用链总览含 Mermaid / 逐层解析 / 数据流转 / 外部依赖与副作用 / 错误与分支 / 断点说明 / 改动风险 / 触达文件清单）。

关键设计点：
- **每一跳带来源标注四选一**：`直接调用` / `provider:接口→实现` / `推断:grep` / `⚠️未能跟进:<形式>`——读者一眼分清哪些可信、哪些是推断。
- **断链不猜**：跟到动态调度（trpc 分发、反射、接口注入）跟不下去时，明标断点 + grep 候选实现，绝不编造边（教条：「错误的边会污染整张图」）。
- **自包含**：关键代码内联（每跳 ≤20 行，超出标 `… (+N 行)`），让读者不必翻源码。
- 两个特殊模式：`mode: shared`（只走热点自身子链，产出公共节点文档）；**定向更新**（收到 `previous_doc_path` + `changed_scope` 时，以上一版为基线只重写受影响部分，但回源抽查保留段）。
- 返回 `DONE/PARTIAL/FAILED` + `touched_files`(含 sha256) + `walked_symbols` + `glossary_candidates`。

### 3.3 子代理 `agents/docgen-flow-review.md`

对抗式事实校验。**只有 Read/Grep/Bash，没有 Write**——只裁决、不改文档。独立重新读源码（不信任 flow 文档结论），逐跳核对：调用边是否真实存在、内联片段是否一致、来源标注是否诚实、Mermaid 边是否真实。

关键设计点：
- **偏向拒绝**：查不到证据支持的跳判 FAIL，而非「姑且信」。
- **每条 FAIL 必须附 `file:line` 证据**，否则编排器视为无效、不据此打回——把举证责任压给 reviewer（它也是 LLM、也会错杀），与「偏向拒绝」对称。
- **以 provider 为裁判**：gopls 可用时，问「A 的 outgoing 里有没有 B」，把「LLM 核对 LLM」换成「gopls 当裁判」。
- 只查事实，不查可读性/完整性/是否漏节点（避免反复打回振荡）。

### 3.4 子代理 `agents/docgen-dir.md`

为单个目录写 `CLAUDE.md` 上下文指引。因为 Claude Code **会自动加载** `CLAUDE.md`，所以两条铁律：
- **保护既有内容**：只动 `<!-- BEGIN/END docgen:auto -->` 哨兵之间的内容；无标记的人工文件 → 追加到末尾，绝不整文件覆盖。
- **是索引不是百科**：只写指针、链到 `docs/flows/*.md` 与 `docs/glossary/terms/*.md`，自动区块 ≤200 行——因为它常驻每次会话上下文，越胖越是永久税。

内容：目录职责 / 关键文件 / 经过的流程（链接）/ 改代码注意事项 / 未覆盖文件。

### 3.5 入口发现 profile `entry-profiles/*.json`

把入口发现规则从命令正文抽成数据。每个 profile：`{ name, lang, file_glob, entry_patterns:[{kind,grep}], false_positive_filters }`。编排器加载全部 profile、按 `file_glob` 选适用项、跑 `grep -nE`、套误报过滤。首期两个：`go-trpc.json`（trpc/gin/net-http/main/cron）、`generic.json`（导出函数兜底）。**加新框架 = 加一个 JSON，不动编排逻辑。**

### 3.6 确定性 hook 层（见 §四详述）

`hooks/hooks.json` 注册三个事件 → `scripts/hooks/` 下三个脚本，共享 `docgen-hooks-common.sh`。

---

## 四、确定性 hook 层（系统的「硬保证」）

三个 hook 全是零 token shell，不可被 LLM 在上下文压力下跳过。它们**是优化与护栏，不是正确性依赖**——编排即使在 hook 全关时也必须正确。

```
SubagentStart(flow)  ── 注入铁律（预防）：章节清单、来源标注四选一、禁止臆测边、≤20行
        │
        ▼
   docgen-flow 干活
        │  每次 Write 前
        ▼
PreToolUse(Write/Bash) ── 写路径越界即 deny（拦截）
        │
        ▼
   docgen-flow 结束
        ▼
SubagentStop(flow)   ── 机械校验产物（出口闸）+ 校验通过写 done 标记
        │  PASS
        ▼
   主线程 → docgen-flow-review（LLM 语义校验，§3.3）
        │  reviewer 结束
        ▼
SubagentStop(flow-review) ── 记录 review 轮次/裁决/未解 issue
```

**职责分工的核心边界**：机械/确定性/最常见的低级错（没写文件、引用不存在的行号、缺章节、缺来源标注、内联超长不截断）→ SubagentStop 在子代理出口就拦下，省掉昂贵的 LLM reviewer 往返；语义判断（A 的实现里到底有没有调 B）→ 留给 LLM reviewer。

### 4.1 SubagentStart → `docgen-subagent-start.sh`
matcher 锁定具体 subagent type，按类型注入各自铁律（仅 `additionalContext`，本事件不支持 block）。同时若输入带 `agent_id`，把「agent_id → 子代理类型」写进 scratch，供 PreToolUse 归因。

### 4.2 PreToolUse → `docgen-pretooluse-guard.sh`
写路径硬护栏。**硬前提**：脚本第一步判「是否正处于一次 docgen run 中」（scratch 子目录是否存在）——不在 run 中立即放行，绝不干预用户无关写操作。在 run 中则按子代理归属做路径校验：flow 只能写 `docs/flows/*.md`、dir 只能写 `CLAUDE.md`、reviewer 任何写一律 deny（含 Bash 重定向）；归因不到则降级为「run 内全局写白名单」。

### 4.3 SubagentStop → `docgen-flow-gate.sh`（一脚本两分流）
按 `subagent_type` 分流：
- **`docgen-flow`**：机械校验五项（文件存在非空 / 章节齐全 / 来源标注 / `file:行` 引用真实且行号合法（设上限抽样）/ 内联 ≤20 行）。任一不达标 → `block` 回传清单让子代理自己补；按 `agent_id` 在 scratch 自管重试计数，命中上限（默认 3）即放行兜底，避免死循环。**全部通过 → 写 `done/<slug>.done`**（含 flow_doc + touched_files），供主线程续跑对账。
- **`docgen-flow-review`**：不做机械校验、绝不 block，只把 reviewer 裁决（PASS/FAIL+issues）确定性写进 `review/<slug>.json`（rounds / last_verdict / open_issues）。

---

## 五、编排工作流（Step A→L）

| Step | 职责 |
|------|------|
| A | 解析 `$ARGUMENTS`（path 必填，`--entry/--max-depth/--lang/--concurrency/--no-review/--no-mermaid/--no-callgraph/--no-shared/--shared-threshold/--profile/--force/--selftest` 等） |
| A.1 | 解析输出语言 `lang`（`--lang` → `$DOCGEN_LANG` → state → 默认 zh-CN，再归一化） |
| B | 定位 `project_root`（`$DOCGEN_PROJECT_ROOT` → git root） |
| C | 展开 `path` 为绝对路径 |
| C.1 | 建 per-run scratch（先清陈旧兜底泄漏，再建 `agents/gate/done/review`）；**写 `run_active` 标志到 state**（含 base_sha，在任何 spawn 前） |
| D | 读/初始化 state（v3.1）；版本 <3 提示 `--force`；**检测 `run_active` 残留 → 进续跑模式，基准用 `run_active.base_sha`** |
| E | 扫候选文件全集（覆盖账本的分母） |
| E.1 | 入口发现（profile + `--entry` 覆盖；误报过滤；空集报错） |
| F | 决定工作集：首跑/`--force` 全量；增量则 **F.2 两级脏判定**（git diff 粗筛 → gopls 符号交集细判，provider 不可用退文件级）、F.3 入口增减、F.4 lang 失配、F.5 刷新覆盖账本 |
| F.6 | 共享热点发现（gopls 算 fan-in ≥ 阈值；为热点 spawn `mode: shared` 流程；业务流程下钻到热点即停） |
| G | 每条流程跑独立流水线：**G.0 续跑恢复分支**（doc 在不在 / review 记录在不在）→ G.1 spawn flow（脏流程带 `previous_doc_path`+`changed_scope` 做定向更新，退出阀 >50% 退全量）→ G.2 更新 state → G.3 review 子循环（FAIL 带 issue 重写，连续两轮相同 issue 即判振荡停） |
| H | 聚合反向索引 `file_to_flows` / `dir_to_flows`，定目录处理顺序（深叶优先、串行） |
| I | 每目录 spawn `docgen-dir` 写 CLAUDE.md |
| J | 合并 glossary（L0 索引 + L1 词条，哨兵保护）；**死词标过期不删** |
| K | 主线程回填流程文档头部校验状态 + banner（K.1 通过/K.2 未收敛/K.3 孤儿/**K.4 过期目录**） |
| L | **L.0 从 scratch done 标记对账** → L.1 写 README → L.2 finalize state（清 `run_active`）→ L.3 清 scratch → L.4 自检断言 → L.5 报告 |

---

## 六、状态文件 schema（v3.1）

`docs/.docgen-state.json` 是唯一的持久产物，续跑与增量都依赖它。关键字段：

```json
{
  "version": 3,                          // 兼容读 3 / 3.1，写回标 3.1
  "last_run": "<ISO>",
  "last_run_sha": "<上次收尾时 HEAD>",
  "run_active": { "started_at": "<ISO>", "base_sha": "<本次启动 HEAD>" },  // v3.1，收尾置 null
  "config": { "project_root","include","exclude","lang","max_depth" },
  "entries": [ { "kind","signature","file","symbol","slug" } ],
  "flows": {
    "<slug>": {
      "entry": {...}, "lang": "...",
      "status": "pending|in_progress|flow_done|review_passed|review_unconverged|orphaned",
      "attempts": 1,
      "flow_doc_path": "docs/flows/<slug>.md",
      "touched_files": { "<rel>": "<sha256>" },
      "walked_symbols": ["<pkg.Symbol@file:line>"],      // v3.1：DFS 实走符号链
      "dirty_granularity": "symbol | file",              // v3.1：本次判定粒度
      "review": { "status","rounds","last_issues" },
      "generated_at": "..."
    }
  },
  "directories": { "<dir>": {...} },
  "file_to_flows": { "<rel>": ["<slug>"] },
  "dir_to_flows":  { "<dir>": ["<slug>"] },
  "shared_to_flows": { "<shared-slug>": ["<business-slug>"] },
  "coverage": { "candidates_total","touched","uncovered":[...] },
  "glossary": { "terms_count","l0_path","generated_at" }
}
```

- **终态**（续跑可跳过）：`review_passed` / `review_unconverged` / `orphaned`；其余整条重跑。
- **平滑升级**：旧 v3 缺 `run_active`/`walked_symbols`/`dirty_granularity` → 按默认值补（`null` / `[]` / `"file"`），不要求 `--force`。

---

## 七、续跑与增量（流程为中心模型）

### 7.1 续跑的原子粒度
- **DFS 生成是原子的**：子代理被打断 → 整条流程重新生成，不做链路半途 checkpoint（DFS 半途无 hook 触发，落盘只能靠 LLM 自觉，违背确定性哲学；且单条被 max_depth 封顶，ROI 低）。
- **review 循环是可续的**：每轮重写后的 doc 本身就是磁盘 checkpoint。reviewer 的 SubagentStop 确定性记录轮次/未解 issue；续跑时若 doc 已存在则重进 review 循环，不重生成、不重跑前 N 轮。
- **状态落盘从 LLM 自觉移到 hook**：done 标记由 SubagentStop 写，主线程收尾对账补回；`run_active` 标志区分「正常收尾」与「上次中断」。scratch「启动即清」，故 done 标记只救同一次 run 内中断；跨 run 真相仍是 state 文件。

### 7.2 增量的两级判定
1. **粗筛（永远先做）**：`git diff` 出 changed_files，文件没动的流程直接跳过（省 gopls 调用）。
2. **细判（仅候选）**：provider 可用且流程符号链可信 → 取「变更文件里变了的符号」与 `walked_symbols` 求交，有交集才重跑（治「同文件无关改动触发整条重生成」的过敏）；provider 不可用 / 非 Go / 降级生成的流程 → 退文件级 sha。
3. **定向更新**：判脏要重跑时，给 flow 喂上一版文档 + 变更范围，只重写受影响部分（减少漂移与 token），但回源抽查保留段；变更覆盖 >50% 符号则退全量。

### 7.3 死数据「标过期不删」
孤儿流程（入口消失）、glossary 死词（来源流程全失效）、过期目录 CLAUDE.md（关联流程全失效）一律打 ⚠️ banner 不删。banner 从反向索引每轮重建，**流程一旦回归即自愈**，无需解除逻辑。

---

## 八、调用图 provider 抽象

一个逻辑接口（写在协议层，非可编译代码）：`CallGraphProvider.outgoing(file, line, symbol) → [{symbol, file, line, kind}]`，`kind ∈ {direct, iface_impl}`。首期唯一实现 `gopls-cli`：探测 `command -v gopls`，可用则用 call hierarchy 拿真实被调边（补掉静态 grep 断在依赖注入/接口的洞），不可用则**降级 grep**，如实标注来源、记 info 日志。`--no-callgraph` 强制全程 grep。这个 provider 同时服务三处：flow 的 DFS、reviewer 的裁判、共享热点的 fan-in 计算。

---

## 九、贯穿全局的设计原则

1. **确定性优先**：能用 shell hook 硬保证的，不依赖 LLM 自觉。
2. **不摧毁、诚实标注**：断点、推断、未覆盖、孤儿、过期——全部显式标注，不假装完整，不删旧产物。
3. **自包含**：流程文档让读者不必翻源码；CLAUDE.md/glossary L0 反过来要「轻到可常驻」，只做索引。
4. **对抗式校验**：生成与校验由独立子代理做，举证责任对称压在双方。
5. **数据驱动可扩展**：入口规则是 JSON profile，加语言/框架不改编排逻辑。
6. **降级而非报错**：gopls 不可用、状态缺字段、git 失败——都有明确降级路径 + 日志，不中断。

---

## 十、文件清单速查

| 文件 | 角色 |
|------|------|
| `commands/docgen.md` | 编排器（主线程，Step A→L） |
| `agents/docgen-flow.md` | DFS 走链 → 流程文档（含 shared / 定向更新模式） |
| `agents/docgen-flow-review.md` | 对抗式事实校验（只裁决） |
| `agents/docgen-dir.md` | 目录 CLAUDE.md 上下文指引（保护人工内容） |
| `skills/docgen/SKILL.md` | 自然语言触发 → 转发 `/docgen` |
| `hooks/hooks.json` | 注册 SubagentStart / PreToolUse / SubagentStop |
| `scripts/hooks/docgen-hooks-common.sh` | 共享助手（run 检测 / scratch 路径 / slug / selftest dump） |
| `scripts/hooks/docgen-subagent-start.sh` | 入口注入铁律 + 写身份标记 |
| `scripts/hooks/docgen-pretooluse-guard.sh` | 写路径硬护栏 |
| `scripts/hooks/docgen-flow-gate.sh` | 出口机械校验 + done 标记 + reviewer 进度记录 |
| `scripts/hooks/tests/*.sh` | hook 行为的 bash 验证（assert + 三个 test） |
| `entry-profiles/*.json` | 入口发现规则（go-trpc / generic） |
| `.claude-plugin/plugin.json` | 插件清单（version 0.6.0，注册 hooks） |
