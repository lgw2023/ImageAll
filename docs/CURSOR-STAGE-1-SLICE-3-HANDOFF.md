# ImageAll 阶段 1 / 切片 3 Cursor 实施交接单

> 状态：Ready for implementation<br>
> 日期：2026-07-15<br>
> 实施者：Cursor CLI，仅 `Composer 2.5 Fast`<br>
> 产品与架构评审：Codex<br>
> 上一批准实现：阶段 1 / 切片 2 `main@f050f4ee0480f4f967be86c5ebffb3a534a30a25`<br>
> Cursor 开工 HEAD：由调用任务中的 `<LAUNCH_HEAD>` 替换为包含本交接单的精确 Codex 文档 commit<br>
> 本轮唯一范围：文件夹流式枚举、媒体分类、lease-bound 资产批次与 generation 完成

## 1. 开工结论与停止位置

阶段 1 / 切片 2 已通过 Codex 终审，批准实现停在只读目录授权引擎与 AppKit 单目录选择器适配；基线为 381 项测试通过、arm64 Debug build 成功。切片 2 Cursor session 已退役。

本切片交付首个真实 `folder.reconcile.v1` handler，但不把它接到 SwiftUI 或常驻 scheduler。实现必须能用合成临时目录和真实临时文件数据库证明：

1. security-scoped 根访问期间流式枚举；
2. 只把批准的静态图片或明确的 `unsupported` / `unreadable` 图片事实写入目录库；
3. Asset、fingerprint、`last_seen_generation` 与 Job checkpoint/progress/lease 在同一事务提交；
4. 只有完整 generation 才能在最终事务判定 `missing`；
5. dirty epoch 变化时，在当前 Job 完成的同一事务排队一个 successor；
6. 崩溃或重试从根重新枚举同一 generation 并幂等收敛；
7. stale 或已过期 lease 不能继续写业务事实。

完成后必须停止。不得生成缩略图、写缓存文件、接入 FSEvents、修改产品界面、运行真实数据 smoke，或进入切片 4。

## 2. 开工门与文档优先级

Cursor 开工前必须按顺序完整读取：

1. [`AGENTS.md`](../AGENTS.md)；
2. 本交接单；
3. [`STAGE-1-IMPLEMENTATION-SPEC.md`](./STAGE-1-IMPLEMENTATION-SPEC.md)，重点第 1～3、5.2、6 节；
4. [`STAGE-1-BACKEND-ARCHITECTURE.md`](./STAGE-1-BACKEND-ARCHITECTURE.md)，重点第 3～10、12～13 节；
5. [`CURSOR-STAGE-1-SLICE-2-HANDOFF.md`](./CURSOR-STAGE-1-SLICE-2-HANDOFF.md)，只继承已批准授权和状态语义；
6. 当前 Job、授权、v001/v002、Catalog 查询和测试代码；
7. [`.cursor/rules/codex-review-handoff.mdc`](../.cursor/rules/codex-review-handoff.mdc)；
8. [`LOCAL-TEST-DATA-SAFETY.md`](./LOCAL-TEST-DATA-SAFETY.md)。

若本文与阶段规格或已批准实现实质冲突，停止并报告，不得自行扩大范围或重解释产品语义。

开工必须证明：

- 使用全新 Cursor session，禁止 `--resume`、Cursor 子代理和 MCP；
- `system/init.model = Composer 2.5 Fast`；
- 当前为本地 `main`，HEAD 精确等于 `<LAUNCH_HEAD>`；
- 工作区除项目所有者已有未跟踪 `user/` 外无其他变化；不得读取、修改、暂存或提交 `user/`；
- 不得 reset、checkout、restore、stash、clean、amend、push 或改写历史；
- 不访问或遍历 `/Volumes/HDD2`，不读取真实 App 容器。

## 3. 持久化边界：不新增 migration

本切片不得新增 migration。现有 schema 已包含本轮所需事实：

- `source.scan_generation`、`source.dirty_epoch`、`source.state`；
- `asset` 的 current/historical locator、media metadata、`content_revision`、`last_seen_generation` 与 availability；
- `file_fingerprint` 的 size、mtime、opaque resource ID 与可选 SHA-256；
- `job` 的 source、checkpoint、scan generation、started dirty epoch、lease、progress 与 control；
- v002 的 generation missing 与 resource ID 索引。

`v001_create_catalog_core` 与 `v002_add_stage_1_catalog_query_support` 必须零字节修改；`CatalogMigrationID.knownOrdered`、快照格式和 `Package.resolved` 不变。若 Cursor 证明现有 schema 无法满足某项原子契约，必须停止并提交差异，不能创建 v003、临时生产表、触发器或复用历史字段表达新语义。

## 4. Application 契约与 Job seam

### 4.1 Payload v1

继续使用切片 2 已发布的：

```text
kind = folder.reconcile.v1
payload_version = 1
payload contract_version = 1
payload source_id = 与 job.source_id 相同的小写 UUID
coalescing_key = folder.reconcile.v1:<source UUID>
```

Payload 只允许上述两个 JSON 字段，不含 bookmark、绝对/相对路径、文件名、用户搜索词或图片内容。未知字段、缺字段、错误类型、非法 UUID、contract/version 不支持、payload `source_id` 与 Job 结构化列不一致都必须在任何目录访问和资产写入前结构化拒绝。

### 4.2 Checkpoint v1

`checkpoint_version = 1`，内容是严格、可版本化的 UTF-8 JSON，仅包含：

| 字段 | 语义 |
|---|---|
| `contract_version` | 固定 1 |
| `generation` | 本 Job 已分配的正整数 generation |
| `started_dirty_epoch` | generation 开始时捕获的非负 epoch |
| `attempt` | 当前 claim 的正整数 attempts 值 |
| `enumerated_entries` | 本 attempt 已枚举的条目数 |
| `candidate_files` | 本 attempt 已进入媒体候选分类的 regular file 数 |
| `committed_assets` | 本 attempt 已提交的资产观察数 |
| `ignored_entries` | 本 attempt 被安全忽略的条目数 |
| `unsupported_assets` | 本 attempt 的 unsupported 资产数 |
| `unreadable_assets` | 本 attempt 的 unreadable 资产数 |
| `identity_conflicts` | 本 attempt 保守拒绝自动重连的身份冲突数 |

所有计数必须为非负整数；不允许额外字段，不保存路径、文件名、bookmark、resource ID、UTI 列表或逐项错误。新 claim 因 FileManager enumerator 不可恢复而从根重跑同一 generation，checkpoint 的 attempt 与本 attempt 计数重新开始；Job `progress_completed` 是跨 attempt 不回退的候选工作高水位，`progress_total` 在本切片保持 `NULL`。最终 completed Job 的 checkpoint 必须反映成功完成的最后一个 attempt。

### 4.3 Lease-bound 执行上下文

当前 `JobHandler.execute` 看不到 lease，且 coordinator 只在 handler 返回后提交一次 Job 行，不能满足多批资产原子提交。实现必须做最小扩展，使真实 reconcile handler 能获得不可伪造的当前 lease 身份，并通过不含 GRDB 类型的 Application 批次端口执行以下操作：

1. `begin generation`；
2. 提交零个或多个资产观察的安全批次；
3. 以“不完整”结果停止而不判 missing；
4. 完整 generation 的最终提交。

具体 Swift 类型名可按现有风格选择，但必须满足：

- Application/Domain 不导入 GRDB、ImageIO、UniformTypeIdentifiers、AppKit 或 `URL`；
- GRDB adapter 独占 SQL 和事务；Foundation/Image I/O adapter 独占绝对根 URL；
- reconcile handler 已经通过批次端口结算 Job 时，`JobExecutionCoordinator` 不得再次 submit 或 double-settle；
- 阶段 0 的简单假 handler 行为和全部既有 Job 测试不回归；
- 不增加 scheduler loop、timer、XPC、LaunchAgent 或 Composition Root 运行接线。

### 4.4 Lease 到期与续租

`lease_owner` 和 `attempts` 相同仍不足以证明 lease 有效。每次业务闭包执行前必须在同一数据库事务验证：

- Job 仍为 `running`；
- owner 与 attempts 匹配；
- 持久化 `lease_expires_at_ms` 在当前时钟之后；等于当前时间即视为已过期。

已过期或被替换的 lease 返回现有结构化 stale-lease 语义，且业务闭包完全不执行。每个 `.continue` 安全边界必须按 claim 的原 lease duration 续租；续租、资产事实、checkpoint 与 progress 同事务。完成、暂停、取消和失败离开 running 时清除 lease。禁止用“给首轮扫描一个极长 lease”替代续租。

### 4.5 Folder 安全错误码

本轮 folder handler 只使用以下稳定、无用户数据的 safe code：

| raw value | 结算 |
|---|---|
| `folderPayloadInvalid` | non-retryable |
| `folderCheckpointInvalid` | non-retryable |
| `folderAuthorizationRequired` | non-retryable；等待重新授权创建新 Job |
| `folderSourceUnavailable` | retryable |
| `folderEnumerationIncomplete` | retryable |
| `folderUnsafeRelativePath` | non-retryable |

stale/expired lease 仍是 JobQueue 结构化错误，不持久化为当前 Job 的 last error，因为该执行者已无写权限。媒体 unsupported/unreadable 与 identity conflict 是 checkpoint 聚合事实，不把整个完整 generation 变成失败。`last_error_message` 保持 `NULL`。

## 5. 流式目录枚举

### 5.1 Foundation 适配

生产实现使用 Foundation 深度 enumerator，预取本轮真正需要的 resource values，并至少启用 hidden 与 package descendant 跳过。不得使用一次性返回完整子树数组的 API，不得先收集所有 URL 再批量处理。

ImageAll 还必须主动执行：

- 所有层级大小写不敏感识别 `.photoslibrary` 并调用 skip descendants；
- package 本身不成为 Asset；
- symlink、Finder alias 不跟随、不成为 Asset；
- 只让 regular file 进入媒体候选；目录、socket、FIFO、device 等忽略；
- 硬链接的不同相对路径仍是不同 Asset；
- 单个目录枚举错误可以继续发现其他项，但必须把整个 generation 标记 incomplete；
- 根在枚举中失效或失权时停止，不判 missing，并沿用切片 2 的 `unavailable` / `authorizationRequired` 状态语义；
- 每次成功进入 security scope 必须恰好 stop 一次，包括异常、pause、cancel、stale lease 与解码失败路径。

默认安全边界上限为 256 个枚举工作单元，测试可以注入更小值。无论 256 项是否都被忽略，都必须提交空资产批次的 checkpoint/lease 边界，避免一个非图片巨型目录长期不续租、不响应控制。任一批次的资产观察数同样不得超过 256；内存中不得保留完整目录 URL 或路径列表。

### 5.2 相对路径

Application 只接收根内相对路径，不接收绝对 URL。相对路径必须：

- 非空、非绝对；
- 使用 `/` 分隔且没有空、`.`、`..` 分量；
- 不含 NUL；
- 标准化后仍严格位于授权根内；
- 保留文件系统原有 Unicode 拼写，不自行 NFC/NFD；
- `file_name` 是最后一个分量，继续满足 v002 约束。

任何逃逸或无法证明仍在根内的结果都使 generation 以 `folderUnsafeRelativePath` 失败；不得把危险项当普通 ignored 后继续发布 missing。

## 6. 媒体候选、分类与首轮元数据

### 6.1 分类算法

扩展名只作低成本候选过滤：先以 `UTType(filenameExtension:)` 判断是否为系统已知 image 候选；非 image 扩展名直接忽略。最终事实必须由运行时 Image I/O source type 和属性再次确认，不能仅相信扩展名。

产品允许集合只从系统 `UTType` 常量取得 canonical identifier：

- JPEG；
- PNG；
- HEIC 与 HEIF；
- TIFF；
- WebP。

分类固定为：

| 观察 | 结果 |
|---|---|
| 非 image 扩展名 regular file | 忽略，无 Asset |
| Image I/O 确认 canonical type 属于允许集合、恰好一个静态主图且属性有效 | `available` |
| Image I/O 确认是图片但 type 不在允许集合，或允许容器实际为多帧/动画 | `unsupported` |
| 允许集合候选但 Image I/O 无法建立 source、无法得到有效主图属性或内容损坏 | `unreadable` |

允许扩展名与实际容器不一致时以 Image I/O 实际 type 为准；例如 `.jpg` 内为合法 PNG 时保存 PNG UTI，`.jpg` 内为非图片/损坏内容时为 unreadable。`.txt` 内即使碰巧是 JPEG 也不进入候选。GIF、RAW、PDF、视频和 Live Photo 不进入 available；PDF/视频等非 image 候选直接忽略，Image I/O 可确认的 GIF/RAW 为 unsupported。

本切片只支持静态图片。多帧 TIFF、APNG、animated WebP、HEICS 等不得伪装成静态 available；保守归为 unsupported。不得在本轮读取整张像素、生成缩略图或缓存解码结果。

### 6.2 元数据与 fingerprint

候选 regular file 写入：

- Image I/O 实际 canonical media UTI；source 无法建立时使用允许扩展名对应的 canonical candidate UTI；
- 方向变换后的逻辑像素宽高；orientation 5～8 必须交换轴；
- 文件 size；
- Foundation/文件系统可稳定提供的最高精度修改时间，持久化为 Unix epoch nanoseconds；
- best-effort opaque resource identifier BLOB；不能稳定编码时为 `NULL`，不得退化为绝对路径或路径 hash；
- 只有拍摄时间本身带 `Z` 或明确数值 UTC offset、能无歧义转成 UTC 时才写 `media_created_at_ms`；无时区 EXIF 日期保持 `NULL`。

`sha256` 本切片始终保持 `NULL`。unsupported/unreadable 候选也保存可取得的快速 fingerprint；unreadable 的宽高可以为 `NULL`。

阶段 1 允许类型与 Image I/O 能力的依据：

- [Apple: Uniform Type Identifiers](https://developer.apple.com/documentation/uniformtypeidentifiers/)
- [Apple: System-declared uniform type identifiers](https://developer.apple.com/documentation/uniformtypeidentifiers/system-declared-uniform-type-identifiers)
- [Apple: CGImageSource](https://developer.apple.com/documentation/imageio/cgimagesource)
- [Apple: Image properties](https://developer.apple.com/documentation/imageio/image-properties)

## 7. Asset 身份与幂等写入

### 7.1 同一路径

对同 Source、同 current relative path：

1. 旧 Asset 已是 `missing`：旧 locator 转 historical，创建全新 Asset；即使 resource ID 相同也不继承标签；
2. 新旧 resource ID 都非空且相等：保留 asset ID；size/mtime 变化时 `content_revision + 1`；
3. 新旧 resource ID 都为空且旧 locator 从未 missing：保留 asset ID；size/mtime 变化时 revision 加一；
4. 新旧 resource ID 都非空且不同：旧 locator 转 historical，创建全新 Asset；
5. 只有一侧 resource ID 或证据互相矛盾：不得猜测。保留 current asset ID、locator、旧 fingerprint 与 revision，标记本轮见过并把 availability 设为 `unreadable`，checkpoint 增加 identity conflict。

新 Asset revision 固定从 1 开始。revision 只在同一身份的快速 fingerprint 改变时逐次加一；单纯 metadata 重新读取或 availability 恢复不增加 revision。

### 7.2 新路径与移动重连

新 relative path 默认创建新 Asset。只有以下条件全部满足才可沿用旧 asset ID：

- 同一 Source；
- 新项 resource ID 非空；
- 数据库中该 Source 恰好一个 current Asset 以该 resource ID 命中；
- 命中 Asset 的旧路径在本 generation 尚未见；
- 在当前 scope 内直接探测旧 locator 后，能证明旧路径已不存在或已指向不同 resource ID。

此时以单事务把旧 Asset 的 locator、metadata、fingerprint 与 `last_seen_generation` 更新到新路径，保留 asset ID 和人工标签。若旧路径仍存在且 resource ID 相同，则是硬链接/第二个出现，必须创建独立 Asset。多个候选、缺失 resource ID、旧路径探测错误或身份无法证明时不自动重连；创建独立 Asset 或按同路径冲突规则保守处理，并增加 conflict count。

本切片不计算 SHA-256，不做跨 Source 去重，不把 size+mtime 当移动证据。

### 7.3 资产观察批次

每个资产观察至少携带：source ID、相对路径、file name、media UTI、逻辑尺寸、媒体时间、availability、size、mtime ns、可选 opaque resource ID。批次端口必须先验证所有值和 source/generation/lease，再在一个事务中：

- 插入或按上述身份规则更新 Asset；
- upsert 对应 `file_fingerprint`；
- 设置 `last_seen_generation`；
- 更新 checkpoint、progress；
- 续租或按 control request 在安全边界离开 running。

任一后段 SQL、约束或 checkpoint 更新失败，整批所有 Asset/fingerprint/last seen/Job/lease 变化回滚。重复提交同一 generation 的同一观察必须幂等，不能重复增加 revision。

## 8. Generation 事务

### 8.1 Begin

首次 begin 在一个写事务中：

1. 验证未过期 lease、Job kind/version/source/payload 一致；
2. 验证 Source 存在、kind=folder、state=active；
3. `source.scan_generation + 1`；
4. 捕获当前 `dirty_epoch`；
5. 把 generation、started epoch 和 checkpoint v1 写入当前 Job。

若当前 Job 已有一对合法的 `scan_generation` / `started_dirty_epoch`，重试必须复用它们，不再次递增 Source。两列只有一列、checkpoint 与结构化列不一致、generation 不属于当前 Source/Job，都以 `folderCheckpointInvalid` 在目录访问前拒绝。

### 8.2 Incomplete

以下情况 generation 不完整，绝不执行 missing：

- 枚举 error handler 收到任何目录错误；
- root 失效、离线或授权失效；
- pause、cancel；
- stale/expired lease；
- unsafe relative path；
- 进程/handler 中断；
- 任一批次持久化失败。

已成功提交的资产批次可以保留；Job 依据第 4.5 节安全结算或由既有 recovery 收敛。下次 claim 从根重跑同一 generation。

### 8.3 Complete

只有 enumerator 正常耗尽、没有目录级错误、根仍可访问、当前 lease 有效且 Source 仍 active，才能进入最终事务。最终事务必须按一个原子单元：

1. 再验证 lease、Job/source/generation 和 control；
2. 若 control 为 pause/cancel 或 Source 已非 active，先按安全边界离开，不判 missing；
3. 把该 Source 下 current file Asset 中 `last_seen_generation` 为空或小于当前 generation 的行标记为 `missing`；
4. 保留 current locator、fingerprint、content revision 和全部人工标签；
5. 写最终 checkpoint/progress；
6. 把当前 Job 设为 completed 并清 lease/control；
7. 若 `source.dirty_epoch != started_dirty_epoch`，在同一事务、当前 coalescing key 释放后插入恰好一个新的 pending `folder.reconcile.v1` Job；否则不创建 successor；
8. Source 保持 active。

missing、当前 Job completion 和 successor 任一 SQL 失败，全部回滚。最终事务重复调用不得产生第二个 successor 或重复改变事实。

## 9. Privacy manifest 与只读安全

切片 3 首次使用文件时间戳 required-reason API，因此必须为生产 App target 增加 `PrivacyInfo.xcprivacy`，且当前只声明：

```text
NSPrivacyAccessedAPICategoryFileTimestamp → 3B52.1
```

不得提前声明 DiskSpace、UserDefaults 或其他类别；不得新增 tracking、collected-data、network、Photos 或其他 entitlement。现有 source entitlement 继续只有 sandbox、user-selected read-only 与 app-scope bookmark；Debug 工具链可额外注入 `get-task-allow`。

生产扫描路径只允许读取来源。不得调用 create/write/remove/move/copy/set-resource-values、写 sidecar、扩展属性或元数据。测试必须对临时 fixture 做扫描前后树、字节和关键 metadata 对比，证明 ImageAll 没有源端写入。

隐私依据：

- [Apple: contentModificationDateKey](https://developer.apple.com/documentation/foundation/urlresourcekey/contentmodificationdatekey)
- [Apple: Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [Apple: Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)

## 10. 强制 TDD 与测试矩阵

先按下列六簇各保留至少一个真实红灯摘要，再做最小实现；不得只在最终代码上补绿灯测试。

### 10.1 契约与执行 seam

- payload/checkpoint 全部正反字段、版本、类型、UUID 与 source 一致性；
- reconcile handler 获得 lease 并能提交多个批次，coordinator 不 double-settle；
- 既有简单 handler/registry/coordinator 全部回归；
- folder safe code 封闭且 last error message 为 NULL。

### 10.2 枚举与路径

- 真实临时多层目录；hidden、package、大小写变体 `.photoslibrary`、symlink、alias、socket/FIFO 忽略且不下钻；
- 硬链接两个路径都可观察；
- fake enumerator 证明不会预收集完整目录，任一时刻 batch/work-unit 上限不超过注入值；
- 256 个全 ignored 项仍产生安全边界；
- 绝对、空、`.`、`..`、NUL、根逃逸逐项拒绝；Unicode 拼写不被正规化；
- 子目录错误、根中途失效、pause/cancel 均 incomplete 且 scope start/stop 配对。

### 10.3 媒体与 metadata

- JPEG、PNG、HEIC、HEIF、TIFF、WebP 的合法静态 fixture 为 available；
- GIF 与至少一个 Image I/O 可识别排除格式为 unsupported；PDF、视频、普通文本忽略；
- 损坏允许格式为 unreadable；伪扩展名以实际容器决定；非 image 扩展名内图片仍忽略；
- 多帧/动画允许容器为 unsupported；
- orientation 1～8 的逻辑宽高，尤其 5～8 交换；
- 明确 offset 的拍摄时间转 UTC，无 offset 保持 NULL；
- SHA-256 始终 NULL，resource ID 不能由路径构造。

### 10.4 身份与资产事实

- 首扫、新增、无变化重扫、同身份内容变化 revision；
- resource ID 不同的同路径替换：旧 historical、新 ID、新 revision=1、不继承标签；
- missing 后同路径重现同样创建新 Asset；
- resource ID 都缺失的连续同路径保留 ID；单侧缺失/矛盾证据走 conflict，不猜测；
- 唯一 resource ID 移动保留 ID/标签；旧路径仍存在的硬链接生成独立 ID；多候选不自动重连；
- unsupported/unreadable fingerprint、metadata NULL 边界与幂等重复批次。

### 10.5 事务、generation 与 lease

- begin 原子递增一次；失败全回滚；retry/reopen 复用同 generation；
- 资产批次后段 Asset/fingerprint/checkpoint/progress/续租任一 fault 均无半批；fault 必须走生产 adapter 和真实临时数据库；
- incomplete generation 永不判 missing；完整删除只在 final 标 missing，保留 locator/fingerprint/tag；
- final missing、Job completion、successor 插入三个后段 fault 各自证明全回滚；
- dirty epoch 未变无 successor，变化时恰好一个；final pause/cancel 优先且不判 missing；
- owner/attempt stale、lease 已过期和恰好到期都在业务闭包前拒绝；continue 正常续租；
- 崩溃 recovery 后从根重跑同 generation，无重复 Asset、revision 或 successor。

### 10.6 隐私、只读与回归

- `PrivacyInfo.xcprivacy` 在生产 bundle 中存在，plist 可解析，且只含 FileTimestamp/3B52.1；
- source fixture 扫描前后目录树、文件字节、mtime 不变；所有测试创建和清理仅限自己的临时根；
- v001/v002、Package.resolved、entitlement、App/SwiftUI、Composition Root、target/scheme 无非授权变化；
- Domain/Application 无 GRDB/ImageIO/UTType/AppKit/URL 泄漏；
- 全部既有 381 项测试与 arm64 Debug build 无回归；
- 无 `/Volumes/HDD2`、真实 App container、PhotoKit、FSEvents、thumbnail/cache I/O。

## 11. 明确禁止

- 不修改任何 SwiftUI、RootView、Sidebar、网格、Inspector、菜单或“连接文件夹…”入口；
- 不修改 App 启动 gate、Composition Root 或启动 scheduler；
- 不新增 migration、表、索引、生产 trigger、GRDB 版本或依赖；
- 不生成缩略图，不写 Application Support/Caches，不做配额/DiskSpace；
- 不接入 FSEvents、PhotoKit、Vision、Core ML、OCR、hash 全库任务或 AI；
- 不访问 `/Volumes/HDD2`，不遍历 `.photoslibrary`，不读取/修改/提交 `user/`；
- 不运行 App 对真实目录的 smoke；
- 不修改 Codex 文档或任务记录；
- 不 push、amend、reset、checkout、restore、stash、clean 或改写历史。

## 12. 验收、提交与交回

至少执行：

```bash
xcodebuild -scheme ImageAll -destination 'platform=macOS,arch=arm64' -configuration Debug test
xcodebuild -scheme ImageAll -destination 'platform=macOS,arch=arm64' -configuration Debug build
plutil -lint <built-app>/Contents/Resources/PrivacyInfo.xcprivacy
codesign -d --entitlements :- <built-app>
git diff --check
```

从 `.xcresult` 或测试输出报告准确 passed/failed/skipped，不沿用旧总数。另需提供：

- 六簇 TDD 红灯→绿灯摘要；
- 最大 batch/work-unit 的可测证据；
- v001/v002 零 diff 和无新 migration；
- 三类事务 fault 的真实生产路径证据；
- Privacy manifest 原始类别/原因摘要与实际 bundle 路径；
- source read-only 对比、scope 配对和 `/Volumes/HDD2` 零访问声明；
- Swift 6、macOS 15、arm64、签名 entitlement、依赖方向和 UI 零变更检查。

通过后只创建一个窄范围本地 commit：

- author/committer：`Cursor Agent <cursoragent@cursor.com>`；
- subject：`feat(cursor): add lease-bound folder reconciliation`；
- trailer：`Agent-Role: implementation`；
- 不含 `Co-authored-by`，不提交 docs 或 `user/`，不 push。

交付后停止并按 `.cursor/rules/codex-review-handoff.mdc` 输出中文复审材料，明确未进入切片 4、5 或 6 UI。

## 13. Codex 重点复审点

1. 是否真正流式并在全 ignored 大目录仍有安全边界；
2. Image I/O 实际 type、静态性与方向 metadata 是否按合同分类；
3. 同路径替换、missing 重现、硬链接、唯一移动与冲突是否不误继承标签；
4. 资产批次与 Job checkpoint/lease 是否同事务且真实 fault 可证明回滚；
5. incomplete 与 final missing 是否严格隔离，dirty successor 是否恰好一次；
6. lease expiry 是否在业务闭包前验证且 continue 会续租；
7. Privacy manifest 是否只增加 FileTimestamp/3B52.1；
8. 是否没有 UI、FSEvents、缩略图、migration、真实数据或源端写入越界。
