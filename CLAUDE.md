# CLAUDE.md
## Git 提交规范
1. **提交格式**：commit message 必须匹配 `feat:|fix:|to:|docs:|style:|refactor:|perf:|test:|revert:|chore:|Merge|merge`，不要加括号限定词（如 `feat(xxx):` 会被拒绝，应写 `feat: xxx`）
2. **不携带 Co-Authored-By**：commit message 中不要添加 `Co-Authored-By` 行
3. **中文描述**：commit message 优先用中文描述

## 交互规范
1. **提问不改代码**：当用户是在提问（而非下达修改指令）时，只做分析和回答，不得直接修改代码。需要修改代码时必须先征得用户同意。
2. **临时文件存放**: 临时文件请放在 `docs` 目录下
3. **回答问题和输出计划/文档**: 不要出现大量中文混合外部英文术语/黑话缩写，比如 "配置块以 legacy chunk_type 落库","能 registry 化的 registry 化" 这种中文参杂外部英文单词的表述,表达清晰为第一要义

## 代码规范
1. **错误处理/逻辑中断分支需打日志**：在 `return err`、不符合预期的 `continue`、`return` 等中断分支前，必须打印相关日志，包含足够的上下文（关键参数、错误信息），便于线上排查；不要静默吞掉错误或异常分支。
2. **必要的代码注释**：
   - 函数实现需给出函数用途、入参与出参（关键字段）的说明，公开导出函数尤其要写明语义与失败条件。
   - 关键变量定义需要简要说明其作用、生命周期或单位。
   - 注释聚焦"为什么"和"关键设计点"，避免逐行解释代码做了什么。
   - 注释尽量避免英文单词，团队内认为中文更可读。
3. **pb/trpc代码生成**: *.pb.go 和 *.trpc.go 文件不要直接生成，而是通过根据 protocol/pb/模块名 下的 *.go 注释方式生成, 例如: cat protocol/pb/setting/setting.go | grep "trpc create", 通过 trpc create -p rule.proto ... 生成 rule.pb.go 和 rule.trpc.go

## 单元测试规范
1. **新增代码必须配套单元测试**：新增/修改的函数（尤其是含分支、错误处理、外部依赖编排的逻辑）必须补充对应单元测试，覆盖成功路径与关键失败/边界分支；不要只改实现不补测试。
   - 改动既有函数签名时，同步更新所有调用方测试与 mock（接口 mock、手写 mock）使其编译通过。
   - 复用既有测试脚手架：`gomonkey.ApplyMethod` patch 具体仓储方法（如 `*mysql.XxxDB`），或 `gomock` 接口 mock（如 `svcmock.NewMockXxx`）；外部 client（如 COS）可手写最小 mock。
2. **如何执行单元测试**：
   - 必须先 `export GOLANG_PROTOBUF_REGISTRATION_CONFLICT=warn`，否则部分包会因 proto 文件重复注册（如 `data.proto` 被多个包注册）在 init 阶段 panic，测试二进制无法启动。
   - 使用 `-mod=vendor`（仓库自带 vendor，`-mod=mod` 会触发外网下载）。
   - 涉及 gomonkey 的用例需加 `-gcflags=all=-l` 关闭内联，否则 patch 可能不生效导致偶发 panic。
   - 按包运行，避免触发无关包的预存 init panic。示例：
     ```bash
     export GOLANG_PROTOBUF_REGISTRATION_CONFLICT=warn
     go test -mod=vendor -gcflags=all=-l \
       git.woa.com/edgeone/edgeone/go/app/setting/internal/service \
       -run 'TestXxx' -count=1 -v
     ```
