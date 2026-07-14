# ImageAll 阶段 0 / 切片 4 Cursor 实施交接单

> 状态：Ready for implementation  
> 日期：2026-07-14  
> 实施者：Cursor CLI（仅 `Composer 2.5 Fast`）  
> 产品与架构评审：Codex  
> 已批准功能基线：`main@332c2a1`  
> Cursor 开工基线：包含本交接单、由 Codex 调用任务明确给出的最新本地 `main` HEAD  
> 本轮范围：持久化 Job 状态机、原子 claim、控制请求、checkpoint 事务、重试与崩溃恢复；不包含真实调度锁、快照恢复或启动集成

## 1. 交接结论

阶段 0 切片 3 已通过 Codex 复审。已批准的目录库基线包含不可变的 `v001_create_catalog_core`、六张 STRICT 业务表、七个命名业务索引和最小 Catalog Repository；当前全套测试为 123 项，Debug build 通过。

Cursor 现在获准实施切片 4：在现有 `job` 表之上建立不依赖 UI 的持久化任务状态机，证明合法/非法转换、原子 claim、lease 所有权、协作式 pause/cancel、checkpoint 与模拟业务写入同事务、确定性重试、遗留 running Job 恢复，以及未知 handler/version 的安全终止。

本轮完成后必须停在切片 4，等待 Codex 独立复审。不得进入切片 5 的快照/恢复或切片 6 的 AppPaths、进程锁、正式库启动和 readiness UI。

## 2. 文档优先级与开工门

Cursor 开工前必须完整阅读，优先级从高到低：

1. [`AGENTS.md`](../AGENTS.md)：角色、Cursor CLI 模型/权限、Git 与真实数据边界；
2. 本交接单：切片 4 的当前执行范围、精确语义和停止位置；
3. [`STAGE-0-IMPLEMENTATION-SPEC.md`](./STAGE-0-IMPLEMENTATION-SPEC.md)：重点是第 3.2、4.1 `job`、4.3、6、8、9.4 节；
4. [`ARCHITECTURE.md`](./ARCHITECTURE.md)：重点是第 12、15、17.3 节与 ADR-006；
5. [`CURSOR-STAGE-0-SLICE-3-HANDOFF.md`](./CURSOR-STAGE-0-SLICE-3-HANDOFF.md)：只用于理解已批准的数据库边界，不是本轮任务单；
6. [`LOCAL-TEST-DATA-SAFETY.md`](./LOCAL-TEST-DATA-SAFETY.md)：阶段 0 只能使用临时目录与合成数据。

若本交接单与阶段规格存在实质矛盾，必须停止并报告，不得自行选择。若实现发现 v001 缺少本契约所需能力，也必须先停止；不得原地修改 `v001_create_catalog_core`，不得自行追加 migration。

开工证据必须包含：

- `system/init.model = Composer 2.5 Fast` 与 Cursor session ID；
- Codex 调用任务声明的开工 HEAD、其父功能基线 `332c2a1`、分支和工作区状态；
- 现有未提交内容的来源说明；若存在来源不明且与本任务重叠的改动，停止；
- 不访问 `/Volumes/HDD2` 的声明。

## 3. 分层与最小交付

### 3.1 允许新增的职责

建议目录职责如下，具体文件名可按现有风格调整：

```text
Application/Jobs/
├── Job 公开值、命令、结果与结构化错误
├── 可控 Clock、RetryPolicy、Handler / Registry 端口
└── 单次执行协调器（claim → validate → handler outcome）

Infrastructure/JobQueue/
├── GRDB 持久化 Job Queue
├── 条件更新、lease 校验与事务边界
└── 遗留 running Job 恢复
```

依赖方向固定为：

```text
Domain ← Application/Jobs ← Infrastructure/JobQueue
```

- Application 不得导入 GRDB，不得暴露 `Database`、SQL、Record 或 `DatabasePool`；
- Infrastructure 可以导入 GRDB，但不得导入 SwiftUI；
- App/Composition Root 本切片不组装 Job Queue；
- 事务型模拟业务写入所需的 GRDB closure 或 transaction collaborator 必须留在 Infrastructure 边界，不能泄漏到 Application-facing API；
- 不为单一实现提前拆新 Swift module、target、XPC、LaunchAgent 或 service。

### 3.2 本轮必须交付

1. Job enqueue 与结构化冲突错误；
2. 原子 `claimNext` 与确定性选择顺序；
3. lease 身份及 stale lease 拒绝；
4. 状态命令与完整合法/非法转换保护；
5. 单调 pause/cancel 请求；
6. 模拟业务批次与 checkpoint/progress 同事务提交；
7. retryable failure、到期重排队和 attempts 耗尽终止；
8. 遗留 running Job 的确定性恢复；
9. handler registry 对未知 kind / 不支持版本的安全 terminal failure；
10. 可控时钟、假 handler 和真实临时文件数据库测试。

### 3.3 明确不做

- 不修改 v001 或任何已批准 migration；
- 不创建新表、索引、trigger、view、FTS 或测试专用生产 schema；
- 不实现 AppPaths、Application Support 正式路径或用户容器 I/O；
- 不实现真正的进程级文件锁；该锁与“第二实例不能打开正式库”由切片 6 完成；
- 不把恢复 API接入 App 启动；切片 4 只固定其事务语义，并声明调用者必须已经持有独占调度锁；
- 不实现 snapshot、backup manifest、WAL 替换、quarantine 或恢复 UI；
- 不实现文件夹扫描、PhotoKit、缩略图、Vision、模型、真实 handler 或无限循环 scheduler；
- 不改 `foundationReady`，不引入 `CatalogReady`；
- 不新增 package、target、scheme、entitlement 或 remote；
- 不访问受保护真实照片。

## 4. Job 值与持久化契约

### 4.1 状态与控制请求

Application 必须提供不依赖 GRDB 的封闭值：

- 状态：`pending`、`running`、`paused`、`retryableFailed`、`completed`、`terminalFailed`、`cancelled`；
- 控制请求：`none`、`pause`、`cancel`；
- 三个终态：`completed`、`terminalFailed`、`cancelled`；
- 四个活动 coalescing 状态：`pending`、`running`、`paused`、`retryableFailed`。

raw value 必须与 v001 精确一致。Infrastructure 读取未知 raw value 时返回结构化持久化错误，不得猜测映射。

### 4.2 Job 身份、payload 与错误

- ID 使用现有 v001 接受的小写规范 UUID；
- `kind` 是非空、可扩展 discriminator，不在 Application 中定义全局封闭 enum；
- enqueue 时固化 `payload_version >= 1`、payload、`max_attempts > 0`、priority、not-before、可空 source 和 coalescing key；
- attempts 创建时为 0，只能由成功 claim 在同一事务中加 1；
- checkpoint 必须保持 version/data 同空同非空；
- 自动恢复、重试耗尽与 registry 拒绝至少使用稳定错误码：`interrupted`、`attemptsExhausted`、`unknownJobKind`、`unsupportedPayloadVersion`、`unsupportedCheckpointVersion`；
- 阶段 0 自动失败只持久化安全错误码，`last_error_message` 保持 NULL。不得把底层错误、完整路径、bookmark、Photos identifier 或 payload 内容写入日志/错误列。

### 4.3 Lease 身份

claim 返回的 lease/claim token 至少包含：

- job ID；
- lease owner；
- 本次 claim 后的 attempts 值；
- lease expiry；
- handler 所需的 kind、payload/checkpoint 版本与数据快照。

后续 handler 提交、完成或失败必须同时匹配 `id + running + lease_owner + attempts`。仅匹配 owner 不够，因为同一 worker 名称可能在后续 attempt 被复用；旧 token 必须被拒绝且不改变记录。

MVP 不根据 wall-clock lease expiry 在同一进程内抢占 running Job，也不实现 lease stealing/renewal。独占进程锁退出后，切片 6 才会调用本切片的遗留恢复；这种设计避免两个执行者同时提交。`lease_expires_at_ms` 本轮仍须在 claim 写入并在离开 running 时清空。

## 5. 状态命令契约

### 5.1 唯一允许的状态转换

| 当前状态 | 命令 / 事件 | 下一状态 | 附加效果 |
|---|---|---|---|
| pending | claim | running | attempts +1；写 owner/expiry |
| pending | pause | paused | control 保持 none |
| pending | cancel | cancelled | 进入终态 |
| running | successful final commit | completed | 清 lease/control/error |
| running | safe boundary sees pause | paused | 已提交批次保留；清 lease/control |
| running | retryable error | retryableFailed 或 terminalFailed | attempts 未耗尽才可重试；清 lease/control |
| running | non-retryable error | terminalFailed | 清 lease/control |
| running | safe boundary sees cancel | cancelled | 已提交批次保留；清 lease/control |
| retryableFailed | retry time reached | pending | 只在 not-before 到期且 attempts 未耗尽 |
| retryableFailed | attempts exhausted | terminalFailed | 不再 claim |
| retryableFailed | cancel | cancelled | 进入终态 |
| paused | resume | pending | not-before 设为命令给定时间；control none |
| paused | cancel | cancelled | 进入终态 |

表外转换全部非法。终态不能复活；需要重跑必须 enqueue 新 Job。非法命令返回包含 current state 与 operation 的结构化错误，数据库行逐列不变。

不得提供一个绕过规则的公共 `setState` API。测试可采用表驱动命令矩阵证明所有入口。

### 5.2 pause/cancel 单调性

- pending pause/cancel 与 paused/retryableFailed cancel 直接执行上表状态转换；
- running 状态只写 `control_request`，state 继续为 running；
- 有效顺序为 `none → pause → cancel`；
- 重复同一请求按幂等成功；
- cancel 已存在时，再请求 pause 或 cancel 都保留 cancel；
- 不提供把请求改回 none 的外部命令；只有安全批次边界离开 running 时清空；
- pause 后到达的 cancel 必须在并发/顺序测试中获胜。

所有控制请求都必须使用条件更新；不能先在一次 read 中判断，再在另一事务中无条件写回。

### 5.3 安全批次边界的唯一决策顺序

handler 到达安全批次边界后，事务内必须重新读取持久化的 `control_request`，再按以下表决策。控制请求优先于 handler outcome；这保证在边界前已落库的 cancel 一定获胜，pause 也不会因为同一批次恰好报告完成或失败而被跳过。

| 最新 control | handler outcome | 下一状态 | error 处理 |
|---|---|---|---|
| cancel | continue / completed / retryable error / non-retryable error | cancelled | 清空 error |
| pause | continue / completed / retryable error / non-retryable error | paused | 清空 error |
| none | continue | running | 清空 error，保留 lease |
| none | completed | completed | 清空 error 与 lease |
| none | retryable error，attempts < max | retryableFailed | 写安全 error code 和 RetryPolicy 时间，清 lease |
| none | retryable error，attempts = max | terminalFailed | 写 handler 的安全 error code，清 lease |
| none | non-retryable error | terminalFailed | 写 handler 的安全 error code，清 lease |

`continue`、`completed` 和两类 error 是本切片固定的最小 handler outcome 集合。pause/cancel 获胜时，本批次已经提交的业务写、checkpoint 和 progress 仍保留；只是最终 state 采用用户控制请求。离开 running 时统一把 `control_request` 置回 none。

### 5.4 转换字段副作用

所有实际行变更都把 `updated_at_ms` 写为注入时钟的当前值；幂等 no-op 必须逐列不变，包括不刷新 `updated_at_ms`。其余字段规则固定如下：

| 操作 | not-before | error | lease / control |
|---|---|---|---|
| enqueue | 使用命令值 | 两列 NULL | lease NULL；control none |
| claim | 保留 | 两列清空 | 写 lease；control 保持 none |
| pending → paused/cancelled | 保留 | 两列清空 | lease NULL；control none |
| paused → pending | 写 resume 命令给定时间 | 两列清空 | lease NULL；control none |
| running control 请求升级 | 保留 | 不变 | 只按 none → pause → cancel 升级 control，保留 lease |
| safe boundary continue | 保留 | 两列清空 | 保留本次 lease；control none |
| safe boundary completed/paused/cancelled | 保留 | 两列清空 | lease NULL；control none |
| retryable failure | 写 RetryPolicy 结果 | 写安全 code；message NULL | lease NULL；control none |
| non-retryable / attempts 耗尽 failure | 保留 | 写安全 code；message NULL | lease NULL；control none |
| retryableFailed 到期提升 pending | 保留已到期时间 | 保留上次 error，直到下一次 claim 清空 | lease NULL；control none |
| retryableFailed 因耗尽转 terminalFailed | 保留 | code 固定改为 `attemptsExhausted`；message NULL | lease NULL；control none |
| retryableFailed → cancelled | 保留 | 两列清空 | lease NULL；control none |
| 遗留 running 恢复为 paused/cancelled | 保留 | 两列清空 | lease NULL；control none |
| 遗留 running 恢复为 retryableFailed | 写 RetryPolicy 结果 | code `interrupted`；message NULL | lease NULL；control none |
| 遗留 running 恢复为 terminalFailed | 保留 | code `interrupted`；message NULL | lease NULL；control none |

未在表中列出的业务列必须保留。checkpoint/progress 只有成功的安全批次提交可以改变；普通状态命令、claim、retry promotion 和恢复不得改写它们。

## 6. enqueue 与原子 claim

### 6.1 enqueue

- 只接受满足 v001 约束的输入；
- source 非空时必须存在，否则返回 `referenceNotFound`；
- 活动 coalescing key 冲突返回稳定的结构化 `activeCoalescingConflict`，不得向上泄漏原始 SQL 文本；
- coalescing key 为 NULL 时不去重；
- 终态同 key 不阻止新 Job；
- enqueue 不验证 handler 是否已注册。未知 kind/version 必须能够入队，并按第 9 节在 claim 后安全终止。

### 6.2 claimNext

一次 claim 必须在一个 `DatabasePool.write` 事务中完成：

1. 选择 `state = pending`、`not_before_ms <= now` 且 `attempts < max_attempts` 的一行；
2. 排序固定为 `priority DESC, not_before_ms ASC, id ASC`；
3. 条件更新为 running，写 lease owner/expiry，attempts 加 1；
4. 读取并返回更新后的 claim token；
5. 无可运行项返回“没有 Job”，不是错误。

owner 必须非空，lease duration 必须为正，所有时间使用注入的毫秒时钟。选择与更新不能跨两个 `pool` access closure。

GRDB 7.11.1 的 `DatabasePool.write` 会串行化写入并包裹事务；本轮仍必须使用带旧状态/attempts 条件的 UPDATE，不能只依赖当前只有一个 writer。参考固定版本官方说明：<https://github.com/groue/GRDB.swift/blob/v7.11.1/README.md>。

### 6.3 并发证明

- 使用同一个真实临时文件库，至少两个并发调用者同时 claim；
- 单个待执行 Job 只能被一个调用者取得，另一个得到 nil；
- 多个 Job 时每个 ID 最多被 claim 一次；
- 测试不能只用 mock、actor 串行化或预先分配不同 Job；
- 不要求本切片启动第二个 App 进程。进程锁及正式库打开顺序属于切片 6。

## 7. handler 执行与事务批次

### 7.1 Handler Registry

Application 层定义最小 handler/registry 端口：

- 根据 kind 查找 handler；
- handler 明确声明支持的 payload version；
- checkpoint 非空时明确声明支持的 checkpoint version；
- 阶段 0 只注册假 handler，不实现真实扫描任务。

单次执行协调器的顺序固定：先 claim，再验证 registry 与版本，再调用 handler。以下情况均把已 claim Job 安全转为 terminalFailed、清 lease/control，并写对应安全错误码：

- 无 handler；
- payload version 不支持；
- 非空 checkpoint version 不支持。

这些情况不得崩溃、反序列化为猜测格式、回到 pending 或留下 running 行。

### 7.2 最小职责时序与边界

本切片固定以下调用方向，避免为了尚不存在的真实 handler 发明通用业务写 DSL：

1. Application 的单次执行协调器通过 Application 定义的 `JobQueue` 端口调用 claim；
2. 协调器把 claim 中的数据快照交给 registry，完成 kind/payload/checkpoint version 校验；
3. 校验通过后，协调器调用不依赖数据库的 handler；handler 只返回第 5.3 节的数据型 outcome、checkpoint 与 progress，不接收 GRDB、SQL 或数据库 closure；
4. 协调器把结果与 lease token 交回 `JobQueue` 端口；GRDB 实现以条件更新提交队列字段；
5. 需要与目录事实同事务的真实 handler 将来由各自的 Infrastructure repository/adapter 组合本节第 7.3 节的内部事务原语。本切片没有真实业务 handler，不设计跨所有业务的通用 mutation 类型。

因此，Application-facing 类型只能包含值、命令、结果、handler/registry/queue 端口和协调器；具体 SQL 与事务 callback 都停留在 Infrastructure。阶段 0 的假 handler 用于验证调用顺序、版本拒绝和 outcome；模拟业务写事务测试直接覆盖 Infrastructure 内部原语，不把测试 closure 暴露为 Application 契约。

### 7.3 批次与 checkpoint 原子性

Infrastructure 必须提供一个受 lease token 保护的事务边界，使以下内容同成同败：

1. 一项模拟业务写入；
2. checkpoint version/data；
3. progress；
4. 根据 handler outcome 与最新 control_request 决定继续 running、completed、paused 或 cancelled；
5. 必要的 lease/control/error 清理。

模拟业务写入使用现有 v001 表中的合成记录，例如更新一个测试 Source 的安全数值字段；不得为测试新增生产表。若采用 GRDB transaction closure，它只能位于 Infrastructure API/测试边界，不能进入 Application 类型。

必须证明：

- 业务写入失败时 checkpoint/progress/state 不变；
- checkpoint/state 更新失败时业务写入回滚；
- 两者成功时同时可见；
- pause/cancel 请求不会回滚此前已提交批次；
- 当前批次与 checkpoint 提交后，pause/cancel 在同一事务结算为 paused/cancelled；
- stale/wrong lease 不能提交业务写入，也不能改变 Job；
- progress 不得回退或超过 total，继续服从 v001 CHECK。

故障注入方式固定，不得为此增加生产 hook、生产 trigger 或新 schema：

- “业务写失败”测试：Infrastructure 内部事务 callback 在写入模拟 Source 变更后主动抛出测试错误，证明 Job 与 Source 一起回滚；
- “Job/checkpoint 写失败”测试：通过 `@testable` 访问 Infrastructure 内部事务原语，在模拟 Source 变更后提交违反现有 v001 progress CHECK 的 Job 更新，证明 Source 变更回滚；公开 Application 入口仍须提前拒绝非法 progress；
- “多行恢复中途失败”测试：只在该临时测试库的 writer 连接创建 `TEMP TRIGGER`，针对排序中的非首行 `UPDATE` 执行 `RAISE(ABORT, ...)`；调用恢复后证明所有目标行逐列不变。trigger 只存在于连接级 TEMP schema，测试结束随临时库销毁，不得进入 migration 或生产 schema dump。

## 8. 重试与崩溃恢复

### 8.1 可控时钟与 RetryPolicy

- Application 使用注入时钟，生产逻辑和测试不得直接读取 `Date.now`；
- RetryPolicy 以 now、attempts、max attempts 和安全错误码为输入，返回确定性 next not-before；
- 本切片不冻结指数退避产品参数。测试注入固定/表驱动策略；
- retryable failure 在 attempts 未耗尽时进入 retryableFailed 并写 next not-before；
- 一个幂等的 retry settlement 入口同时处理两类行：`attempts >= max_attempts` 时不等待 not-before，立即条件更新为 terminalFailed 并写 `attemptsExhausted`；其余行只有 not-before 到期才提升为 pending；
- 到期提升为 pending 必须是条件更新；未到期不变；
- attempts 已耗尽时直接或在恢复事务中进入 terminalFailed，永不再次 claim。

### 8.2 遗留 running 恢复

恢复入口有硬前置条件：“调用方已持有应用进程级独占调度锁”。切片 4 不制造假锁 token，也不把入口接到 App；切片 6 必须在取得真实锁后调用。

一次恢复在单个事务中处理所有遗留 running Job：

1. control = cancel → cancelled；
2. control = pause → paused；
3. control = none 且 attempts < max → retryableFailed，错误码 `interrupted`，按 RetryPolicy 写 not-before；
4. control = none 且 attempts >= max → terminalFailed，错误码 `interrupted`；
5. 所有离开 running 的行清 lease 和 control；
6. 非 running 行完全不变。

恢复失败必须整体回滚，不允许一部分遗留 Job 已恢复、另一部分仍 running。之后由正常“到期 retryableFailed → pending”操作重排队，不在同一恢复调用中跳过可观察的 retryableFailed 语义。

## 9. 结构化错误与幂等性

至少区分：

- reference not found；
- active coalescing conflict；
- invalid transition；
- invalid claim input；
- job not found；
- job not running / not claimed；
- stale lease；
- unknown persisted raw value；
- unknown handler kind；
- unsupported payload version；
- unsupported checkpoint version。

错误类型名不固定，但必须 `Equatable`、`Sendable` 或提供等价的稳定比较面。不得把 GRDB/SQLite 自由文本作为上层契约。

幂等行为固定为：

- 同一 running control request 重复提交不会反转；
- cancel 优先级不会下降；
- due retry promotion 可重复调用；
- 恢复在第一次成功后再次调用不改变已恢复 Job；
- complete/fail/batch commit 用同一旧 lease 重试必须返回 stale/invalid，而不是重复业务写入。

## 10. TDD 实施顺序

按下列簇推进，每簇先出现可说明原因的红灯，再最小实现；覆盖缺口而实现已正确时，报告可说明新增测试直接通过，但不得伪造红灯。

| 簇 | 先固定的行为 | 绿灯门 |
|---:|---|---|
| 1 | Application Job 值、命令、错误、时钟/策略端口 | 不导入 GRDB；Swift 6 编译 |
| 2 | enqueue、coalescing、source 引用、读取映射 | 真实临时库正反例 |
| 3 | claim due/order/attempt/lease 与并发唯一性 | 两并发 claimant 不重复 |
| 4 | 完整状态命令矩阵与单调控制请求 | 非法操作逐列不变 |
| 5 | 模拟业务写入 + checkpoint/progress/state 事务 | 故障注入无半批事实 |
| 6 | retry policy、due promotion、attempt exhaustion | 可控时钟边界通过 |
| 7 | 遗留 running 恢复 | cancel/pause/interrupted/耗尽全覆盖 |
| 8 | registry 与未知 kind/version | claim 后 terminalFailed，不残留 lease |
| 9 | 全量回归与边界审计 | 测试、Debug build、diff check 全绿 |

不得用 sleep 建立并发正确性；使用 barrier、task group、信号量或等价的确定性起跑机制。不得依赖测试执行顺序或共享固定数据库。

## 11. 最低测试矩阵

### 11.1 正例

- enqueue 默认 attempts/state/control 正确，payload 原样保存；
- NULL coalescing 可并存，终态同 key 后可新建；
- claim 只选择到期 pending，顺序为 priority/not-before/ID；
- claim attempts +1、lease 写入并返回完整 token；
- 两并发 claim 对同一 Job 只有一个成功；
- 状态图中每条合法边均成功；
- safe boundary 覆盖四种 handler outcome × 三种 control 的完整决策表；
- running pause、pause→cancel、重复 cancel 的单调行为；
- checkpoint + 模拟业务写入 + progress 同时成功；
- safe boundary 分别结算 pause/cancel，已提交批次保留；
- retryableFailed 未到期不动、到期回 pending；
- 遗留 cancel/pause/none running 分别恢复；
- unknown handler/payload/checkpoint version claim 后 terminalFailed；
- 同一恢复/到期提升重复调用幂等。

### 11.2 反例

- source 不存在、活动 coalescing 冲突；
- 空 owner、非正 lease duration；
- attempts 已耗尽或 not-before 未到不能 claim；
- retry settlement 不等待 not-before 即终止已耗尽行，且未耗尽未到期行逐列不变；
- 状态图外每条命令拒绝且行不变；
- 终态 resume/claim/complete/fail/control 全拒绝；
- wrong owner、旧 attempts token、非 running token 的提交拒绝；
- stale lease 业务 closure 不得执行；
- 业务写入失败与 checkpoint 写入失败分别整体回滚；
- pause 不能覆盖 cancel，外部不能清 none；
- 不支持版本不能调用 fake handler；
- 恢复事务中故障时所有 running 行保持原样；
- persisted unknown raw value 产生结构化错误而非 crash（可用独立可控坏库或测试 migration，不修改生产 v001）。

## 12. 验收门与回传证据

### 12.1 自动化门

- 完整 `xcodebuild test` 退出 0，并从 `.xcresult` 报告实际总数、失败数、跳过数；
- Debug build 退出 0；
- 原 123 项测试无回归；
- 所有 Job 测试使用独立临时文件数据库；
- `git diff --check` 无输出；
- Swift 6、GRDB 7.11.1、target/scheme/entitlement/Package.resolved 不变；
- Domain/Application/Infrastructure 依赖方向通过源码检查；
- 无 `/Volumes/HDD2` 访问、硬编码或产物；
- 无真实 App 启动运行要求；本切片运行证据为真实并发 claim 与恢复集成测试。

### 12.2 Git 门

- 从包含本交接单、由 Codex 调用任务明确给出的本地 `main` HEAD 开工；其已批准功能基线为 `332c2a1`；
- 只提交切片 4 的 Application/Infrastructure Job 与测试文件，以及必要的 Xcode 文件引用；
- 不修改已批准文档、v001、现有 Catalog 语义或 UI；
- 一个窄范围本地实现 commit；若修正需要追加 commit，不改写已审计历史；
- 不 push；交付后工作区干净。

### 12.3 Cursor 必须回传

遵守 `.cursor/rules/codex-review-handoff.mdc`，并额外提供：

1. `system/init.model` 与 Cursor session ID；
2. 开工/交付 commit 与完整文件职责；
3. Job API/端口列表及依赖方向；
4. 状态转换正反矩阵与非法操作“不改变记录”证据；
5. 并发 claim 测试的起跑方式和结果，不只给最终断言；
6. lease token 如何防 stale attempt；
7. checkpoint 与模拟业务写入两种故障方向的回滚证据；
8. pause→cancel、safe boundary 和已提交批次保留证据；
9. retry/recovery 四类路径及确定性时钟参数；
10. unknown kind/payload/checkpoint version 的终止状态、error code、handler 未被调用证据；
11. 完整测试命令、`.xcresult` 总数、Debug build、diff check；
12. v001/依赖/target/scheme/entitlement/UI/HDD2 未变化声明；
13. 明确停止于切片 4、未进入切片 5–6。

## 13. Codex 复审重点

Codex 将独立核对：

- claim 是否真在单个写事务中完成，两个调用者是否可能取得同一 Job；
- 所有更新是否使用旧状态与 lease attempt 条件，stale handler 是否可能提交；
- 状态图、终态和控制请求单调性是否被统一入口保护；
- checkpoint 与业务事实是否真正同事务，不是两个先后成功的调用；
- 重试边界与遗留恢复是否使用可控时钟且失败整体回滚；
- unknown kind/version 是否先 claim 再安全终止，是否泄漏敏感错误内容；
- Application 是否泄漏 GRDB，Infrastructure 是否越界到 UI；
- 是否错误提前实现锁、AppPaths、快照、启动或真实 handler；
- 测试、构建、Git 与模型证据是否可独立复现。

只有切片 4 通过复审，才授权进入切片 5（快照与恢复）。阶段 0 此时仍未完成。
