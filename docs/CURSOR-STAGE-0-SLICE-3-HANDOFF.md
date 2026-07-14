# ImageAll Cursor 实施交接单：阶段 0 / 切片 3

> 状态：Ready for handoff<br>
> 日期：2026-07-14<br>
> 实施者：Cursor<br>
> 产品与架构评审：Codex<br>
> 本轮范围：GRDB 依赖、v001 schema、最小持久化完整性与真实数据库集成测试；不包含 Job 行为、快照恢复或启动集成

## 1. 交接结论

阶段 0 切片 2 已通过复审，批准的实现基线为 `main@80ef5cf`。Cursor 现在获准实施切片 3：引入并锁定 GRDB，建立不可变 migration `v001_create_catalog_core`，创建阶段规格规定的六张表和七个业务索引，并用文件型临时数据库证明 schema、约束、事务与重开语义。

本轮只让“目录库结构及其最小持久化边界”成立，不让 App 打开真实用户目录库。完成后必须停止并交回 Codex 评审；不得进入切片 4 的 Job 状态机，也不得把 `foundationReady` 改成或解释为 `CatalogReady`。

## 2. 开工基线与文档优先级

Cursor 开始前必须完整阅读以下文件，优先级从高到低：

1. [`AGENTS.md`](../AGENTS.md)：角色、范围和修改纪律；
2. 本交接单：切片 3 的执行范围、精确验收门和停止位置；
3. [`STAGE-0-IMPLEMENTATION-SPEC.md`](./STAGE-0-IMPLEMENTATION-SPEC.md)：规范性数据契约，重点是第 3、4、8、9.1 和 9.3 节；
4. [`ARCHITECTURE.md`](./ARCHITECTURE.md)：上位依赖方向、持久化原则和事实/缓存边界；
5. [`CURSOR-STAGE-0-SLICE-2-HANDOFF.md`](./CURSOR-STAGE-0-SLICE-2-HANDOFF.md)：已关闭切片的历史契约，不是当前实施范围。

若本交接单与阶段规格出现实质矛盾，必须停止并报告，不能用实现便利性自行改变 schema、状态词汇、删除策略或索引谓词。

开工门：

- 历史必须包含 `80ef5cf` 和包含本交接单的最新文档提交；
- 分支必须是本地 `main`，工作区必须干净；
- 开工时不得已有未说明的 GRDB、Database、migration、测试或工程草稿；
- 若工作区不干净，先报告每项差异的来源和所有权，不能覆盖、整理或吸收后继续；
- 未取得本交接授权前产生的实现写入不计入本切片交付。

Codex 的交付消息会给出包含本交接单的精确文档 commit；Cursor 必须以该 commit 为开工 HEAD 并在报告中回传，不以“当时最新 main”替代可复现基线。

当前基线有 39 个测试。Cursor 回传时必须报告实际发现并执行的总数，不以 39 作为硬编码断言。

## 3. 本轮固定决策

### 3.1 GRDB 依赖

使用 Swift Package Manager 添加官方仓库：

- 仓库：`https://github.com/groue/GRDB.swift.git`；
- 允许版本：`7.11.1..<8.0.0`；
- 产品：静态 `GRDB`；
- 不使用 `GRDB-dynamic`、`GRDBQuery`、SQLCipher 或其他第三方包；
- Xcode 生成的共享 `Package.resolved` 必须进入版本控制，并证明最终解析版本与 revision；
- 不依赖 branch、`main`、未标记 revision 或本地 package checkout。

截至 2026-07-14，[GRDB 7.11.1](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1) 是官方最新 release。GRDB 7.9 起要求 Swift 6.1 / Xcode 16.3 或更新版本，当前 Swift 6.3.3 / Xcode 26.6 基线满足要求。GRDB 官方文档说明 `DatabasePool` 为可写文件数据库启用 WAL 并允许并发访问，因此本项目选择文件型 `DatabasePool`，与后续后台读写架构一致。

`ImageAll` target 必须链接 `GRDB`。只有测试源直接导入 GRDB 时，`ImageAllTests` 才显式链接同一产品；不能为测试再引入第二种数据库依赖。

### 3.2 数据库连接形态

本切片建立一个基础设施层数据库入口，接收调用方注入的文件 URL 或路径并返回可用的文件型数据库 writer。具体类型命名由实现者按现有风格决定，但职责必须保持最小：

1. 建立并配置连接；
2. 检查已应用 migration 是否为当前应用认识的前缀；
3. 执行已注册 migration；
4. 执行 `PRAGMA quick_check` 并把失败转换成结构化基础设施错误；
5. 为最小 Catalog Repository 提供事务边界。

连接契约：

- 使用文件型 `DatabasePool`，不使用内存库替代正式集成测试；
- 可写数据库为 WAL 模式，测试必须读取 pragma 证明；
- 每个连接启用 foreign key enforcement，测试必须读取 pragma 并用反例证明；
- 不在 UI 主线程或 SwiftUI View 内创建连接、执行 migration 或查询；
- 本切片不决定 busy timeout、缓存大小、mmap 或其他性能调优参数；没有量化证据前保持 GRDB/SQLite 默认值；
- 不加密数据库；数据库和快照的设备级保护属于部署与备份策略，不在 v001 发明密钥系统。

### 3.3 允许的代码范围

本切片允许创建或修改：

```text
ImageAll/Infrastructure/Database/
ImageAllTests/Database/
ImageAll.xcodeproj/project.pbxproj
ImageAll.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

路径以 Xcode 实际生成结果为准；不为匹配示意路径手工复制锁文件。若必须建立极小的 Application Port 才能保持既定依赖方向，应先报告理由；本切片不为尚无调用方的未来用例预建协议层。

基础设施中的数据库 Record、列名和 GRDB 映射不得进入 Domain。现有 Domain 规则与 raw value 是事实来源，切片 3 不修改其语义。若数据库契约无法表达既有 Domain 语义，停止并提交差异，不得静默改 Domain 测试。

### 3.4 明确不做

本切片不得实现或占位：

- AppPaths、Application Support、Caches 或真实用户容器解析；
- 应用级独占调度锁；
- 迁移前快照、工作副本、空间预检、WAL checkpoint、原子替换或恢复；
- Composition Root 数据库组装、启动状态、`CatalogReady` / `CatalogUnavailable` UI；
- Job claim、lease、状态转换、控制请求、checkpoint、恢复、handler registry 或未知版本终止逻辑；
- 文件夹扫描、PhotoKit、bookmark 获取、缩略图、特征、预测或产品界面；
- schema 规格外的表、索引、触发器、视图、FTS 或测试专用生产表；
- 新 target、scheme、entitlement、build script、UI Test 或额外 module。

`job` 表在 v001 中存在仅因为它是阶段 0 的持久化契约。本切片只验证其 DDL 约束和索引；任何 Job 行为属于切片 4。

## 4. v001 schema 契约

### 4.1 migration 身份与表集合

生产 migration 标识固定为 `v001_create_catalog_core`。该标识一旦进入切片 3 已批准提交，后续不得修改内容或改名；变化必须追加新 migration。

现有 Domain raw value 用于核对 v001 的精确拼写，但 migration 内的 CHECK 词汇必须冻结，不能在运行时从未来可能扩展的 `allCases` 或其他可变列表动态生成。将来新增领域状态时必须追加 migration，不能让旧 v001 随新代码静默改变。

v001 必须创建且只创建以下六张业务表：

1. `source`；
2. `asset`；
3. `file_fingerprint`；
4. `tag`；
5. `asset_tag_decision`；
6. `job`。

GRDB 自己维护的 migration bookkeeping 表不算业务表，SQLite 因 PRIMARY KEY/UNIQUE 自动创建的内部索引不算额外业务索引。不得提前创建模型、特征、预测、缩略图、相册或设置表。

列名、SQLite 类型、NULL、默认值、外键动作和基础含义的唯一规范来源是 [`STAGE-0-IMPLEMENTATION-SPEC.md` 第 4.1 节](./STAGE-0-IMPLEMENTATION-SPEC.md#41-v001-精确数据字典)。本交接单不复制整张数据字典，以免双份定义漂移；Cursor 必须从同一文档 commit 读取该节。不能把规范中的可空列擅自改成空字符串/零值，也不能为了 Swift 映射方便放宽 NOT NULL。

六张业务表统一使用 SQLite `STRICT` table，不使用 `ANY`。这使数据字典声明的 TEXT / INTEGER / BLOB 类型成为真实写入约束，并让 `quick_check` 检查列类型；GRDB 自有 migration 表不要求由本项目改成 STRICT。当前 macOS 15 最低版本远高于 SQLite 3.37 的 STRICT 支持门槛，依据见 [SQLite STRICT Tables](https://www.sqlite.org/stricttables.html)。

### 4.2 通用存储规则

数据库边界必须固定：

- 所有持久化 UUID 使用小写 `8-4-4-4-12` 规范文本；数据库级反例测试至少拒绝大写、缺少连字符和非十六进制字符；
- 业务时间使用 UTC Unix epoch milliseconds；`file_fingerprint.modified_at_ns` 保持独立纳秒整数语义；
- 枚举 raw value 精确使用阶段规格封闭词汇，并由 CHECK 拒绝未知值；
- Bool 如未来出现，使用受 CHECK 约束的 INTEGER；v001 不因该规则新增 Bool 列；
- 所有外键在真实连接上生效；
- 写事务任一步失败时整体回滚；
- `tag.normalized_name` 使用 SQLite BINARY 比较，不声明 NOCASE 或本地化 collation；
- 数据库层拒绝零长度的具体字段是 `source.display_name`、`tag.name`、`tag.normalized_name`、`asset.media_type`、file locator 的 `asset.relative_path`、photos locator 的 `asset.photos_local_identifier`、`job.kind`、非 NULL 的 `job.coalescing_key`，以及 running Job 的 `job.lease_owner`；
- BLOB 列必须保持 BLOB storage class；反例至少证明同长度 TEXT 不能冒充 bookmark、SHA-256、payload 或 checkpoint。

Unicode trim、case fold 和 NFC 仍由已通过的 Domain 规则负责。不要尝试用 SQLite 内置 `trim()` 或 `NOCASE` 重新实现 Unicode 语义；Repository 只接收已经通过领域验证的 Tag 名称，数据库提供非空与唯一性的第二层保护。

### 4.3 表级 CHECK 与关系约束

实现和反例测试必须覆盖以下约束族。这里描述行为，不规定 SQL 写法。

#### `source`

- `kind` 仅为 `folder` / `photos`；
- folder 的 bookmark 必须是非空 BLOB，photos 的 bookmark 必须为 NULL；
- `scan_generation`、`dirty_epoch` 均不小于 0；
- `state` 仅为 `active`、`disabled`、`unavailable`、`authorizationRequired`；
- `display_name` 非空；
- 主键 UUID 符合通用格式。

#### `asset`

- `source_id` 引用已存在 Source，删除 Source 时 RESTRICT；
- file locator 只能有非空 `relative_path`，且 `photos_local_identifier` 为 NULL；
- photos locator 只能有非空 `photos_local_identifier`，且 `relative_path` 为 NULL；
- `locator_state` 仅为 `current` / `historical`；
- `availability` 仅为 `available`、`missing`、`unreadable`、`unsupported`；
- width/height 为 NULL 或大于 0；
- `content_revision >= 1`；
- `last_seen_generation` 为 NULL 或不小于 0；
- `media_type` 非空。

规范相对路径的完整解析与来源扫描属于阶段 1。v001 只保证 file locator 字段存在且非空，不在 SQLite 中发明路径正规化算法。

#### `file_fingerprint`

- `asset_id` 是 PRIMARY KEY，引用 Asset 并在 Asset 删除时 CASCADE；
- `size_bytes >= 0`；
- `sha256` 为 NULL 或恰好 32 bytes；
- 只有 file Asset 可以写 fingerprint。SQLite 外键无法表达这项跨表条件，必须由最小 Catalog Repository 在同一写事务中检查并用真实数据库测试证明。

#### `tag`

- `name` 与 `normalized_name` 非空；
- `state` 仅为 `active` / `archived`；
- `normalized_name` 的 BINARY 唯一索引是领域重复检查之外的第二道保护；
- 测试使用切片 2 的标准化结果证明 `Family` / `FAMILY` 不能产生两个规范化相同的 Tag，且不能借助 NOCASE 改变其他 Unicode 字符的比较语义。

#### `asset_tag_decision`

- `(asset_id, tag_id)` 是复合 PRIMARY KEY；
- 两个外键均为 RESTRICT；
- `decision` 仅为 `accepted` / `rejected`；
- `unknown` 仍由“没有行”表达，不能写入数据库。

#### `job`

- `kind` 非空但不设封闭词汇 CHECK；
- `payload_version >= 1`；
- `source_id` 可空，删除 Source 时 SET NULL；
- `coalescing_key` 为 NULL 或非空；
- `checkpoint_version` 与 `checkpoint` 必须同时为空或同时存在，存在时 version 不小于 1；
- `scan_generation`、`started_dirty_epoch` 为 NULL 或不小于 0；
- `state` 精确限制为七个规定值；
- `control_request` 精确限制为 `none`、`pause`、`cancel`，且非 running 状态只能为 `none`；
- `max_attempts > 0`，并且 `0 <= attempts <= max_attempts`；
- running 状态必须同时具有非空 `lease_owner` 与 `lease_expires_at_ms`，其他状态两者都为空；
- `progress_completed >= 0`，`progress_total` 为 NULL 或不小于 completed。

本切片不验证 Job 状态转换是否业务合法，只验证单行能否满足持久化不变量。

### 4.4 跨表一致性

以下规则不能只靠单表 CHECK，必须由最小 Catalog Repository 在单个事务中验证：

- folder Source 只能持有 file Asset；
- photos Source 只能持有 photos Asset；
- Photos Asset 不能持有 `file_fingerprint`；
- 一个多步写入若在后续校验或 SQL 约束处失败，之前写入的 Source/Asset/Tag 等不能留下半批事实。

Repository 只实现证明这些当前契约所需的最少写操作。不要在切片 3 建立完整 CRUD、分页查询、搜索 API、观察器或通用泛型 Repository。

最小写能力限定为：原子创建 Source 及其首个 Asset、向已有 Source 写入 Asset、为已有 Asset 写入或替换 file fingerprint。前两项都验证 Source kind 与 locator kind，第三项验证 Asset 为 file；引用不存在、Source/locator 错配和 fingerprint/Asset kind 错配必须是可区分的结构化错误，测试不能依赖自由文本。类型和方法名不固定。

## 5. 索引契约

v001 必须创建以下七个命名业务索引，名字和语义都固定：

| 索引 | 键 | 谓词 / 目的 |
|---|---|---|
| `asset_current_file_locator_uq` | `(source_id, relative_path)` | unique；`locator_kind = 'file' AND locator_state = 'current'` |
| `asset_current_photos_locator_uq` | `(source_id, photos_local_identifier)` | unique；`locator_kind = 'photos' AND locator_state = 'current'` |
| `asset_source_availability_idx` | `(source_id, availability, id)` | Source 内按可用性稳定查询 |
| `tag_normalized_name_uq` | `(normalized_name)` | BINARY unique |
| `decision_tag_idx` | `(tag_id, decision, asset_id)` | 按标签和决定查询 |
| `job_queue_idx` | `(state, priority DESC, not_before_ms, id)` | 后续队列 claim 顺序 |
| `job_active_coalescing_uq` | `(coalescing_key)` | unique；`coalescing_key IS NOT NULL AND state IN ('pending', 'running', 'paused', 'retryableFailed')` |

partial unique 反例必须证明：

- 同一 Source/locator 的两个 current 记录被拒绝；
- 任意数量 historical 记录可以共存；
- file 与 photos 两种 locator 分别受各自索引保护；
- 相同 non-null coalescing key 在四个活动状态间互斥；
- completed、terminalFailed、cancelled 不占用 key，之后可创建新 Job。

不得新增“可能以后有用”的索引。若 GRDB/SQLite 生成自动索引，schema dump 必须把它们标为系统结果而不是业务设计。

上述 WHERE 条件的状态集合与逻辑必须完全一致；schema SQL 的空白、括号或等价条件顺序不作为失败理由。

## 6. migration 与打开语义

### 6.1 本切片必须证明

- 全新文件型临时数据库可执行 v001；
- 重开并再次运行同一 migrator 不重复创建对象、不删除数据，已应用 migration 列表仍只有一个 v001；
- `PRAGMA quick_check` 返回 `ok`；
- 当前应用在执行新 migration 前检查已应用标识，发现未知 migration 时返回结构化 future-schema 错误并拒绝继续；
- 不启用 GRDB 的 destructive schema-change erase 选项，也不以删除重建空库作为任何错误的回退；
- 一个 migration body 在执行 DDL/DML 后故意失败时，该 migration 内的 schema/data 变更及其 applied marker 都回滚；
- Repository 的多步写事务失败时不留下半批数据。

测试失败 migration 可以在测试代码中构造，不得注册进生产 migration 列表，也不得在生产 schema 留下测试表。

“当前应用认识的前缀”按集合判定：数据库已应用 ID 集合必须等于生产已知有序列表某个前缀的集合，不依赖 migration 表的物理行顺序。切片 3 的已知列表只有 `[v001_create_catalog_core]`，因此合法集合只有空集与 `{v001_create_catalog_core}`；未知 ID 或未来出现的非前缀缺口必须拒绝，重复由 GRDB migration 表自身的主键保护。结构化错误至少携带稳定排序后的已应用 ID 与未知/异常 ID，不携带用户文件路径；具体 Swift 类型名不固定。

本切片只要求 `quick_check = ok` 的正例以及错误不被吞掉；可控坏库、坏 schema 与恢复回滚的系统性反例归切片 5–6，不为制造该反例提前引入可注入 integrity-check 抽象。

### 6.2 明确延后

阶段规格要求正式升级先快照、再在工作副本迁移、验证后原子替换。切片 5 负责已验证快照、候选副本验证与原子替换/回滚原语；切片 6 负责在启动时组合 AppPaths、独占锁、迁移前快照、工作副本 migration、quick check、正式库替换和 readiness 状态。本切片不打开正式路径，因此只证明单个 migration 事务原子性，不能声称“生产原库在多 migration 失败后已受工作副本保护”。

同样，独占调度锁、Application Support 路径、WAL/SHM 替换纪律和打开失败后的 UI 状态都延后；不得用占位实现提前宣称完成。

## 7. TDD 实施顺序

按红—绿—整理推进，每簇只写使当前行为成立的最少实现：

1. **依赖与连接**：先只完成 GRDB package 与最小可编译连接 seam；在该 seam 可编译后，写文件型临时数据库、WAL、foreign key 和 quick check 的行为失败测试，再补最少连接实现；
2. **migration 形状**：先写六表、列、默认值、外键和 migration 标识检查，再实现 v001；
3. **单表反例**：依次固定 Source/Asset、fingerprint、Tag/decision、Job 的 CHECK；
4. **索引行为**：先写 current locator、normalized name 和 active coalescing 的冲突/放行测试，再建立七个索引；
5. **跨表 Repository**：先写 Source/locator 不匹配、Photos fingerprint 和半事务残留测试，再写最小事务边界；
6. **重开与失败**：固定幂等重开、future schema 拒绝和失败 migration 回滚；
7. **全量回归**：生成 schema dump，运行全部测试与 Debug build，检查工程和 Git 边界。

至少保留前六簇中各一个有效红灯证据。有效红灯必须是目标代码已存在但行为不满足契约；纯粹的文件缺失、包未下载、target 不编译、网络错误或故意 `XCTFail()` 不算行为红灯。

红灯证据可以保存在实施报告附带的终端日志中，不要求为每个红灯创建 commit，也不要求把故意错误的中间代码留在最终历史。最终仍只交付一个切片 3 实现 commit。

每个数据库测试使用独立临时目录和独立数据库文件，不访问真实用户容器，不依赖测试顺序。测试只清理自己创建的临时目录。

## 8. 最低测试矩阵

| 行为族 | 必须包含的正例 | 必须包含的反例 |
|---|---|---|
| 连接 | 文件库打开、WAL、writer 与至少一个独立 reader 连接均 FK=ON、quick_check=ok | FK 缺失引用被拒绝 |
| migration | 空库创建 v001、重开数据保留 | 未知 future migration 被拒绝；失败 migration 回滚 |
| schema | 六张 STRICT 表、精确列/默认值/FK、七索引 | 无规格外业务对象；错误 storage class 被拒绝 |
| UUID/词汇 | 规范 UUID、所有允许 raw value | 大写/畸形 UUID、每组未知 raw value |
| Source/Asset | folder+file、photos+photos | bookmark 错配、locator 列错配、Source kind 与 locator kind 错配 |
| 数值/Blob | 合法尺寸、revision、generation、32-byte hash | 负数、零尺寸、revision 0、错误 hash 长度 |
| locator unique | current 唯一、historical 共存 | file/photos current locator 重复 |
| Tag/decision | BINARY normalized 唯一、accepted/rejected | duplicate normalized、unknown 行、重复 Asset/Tag 对 |
| Job DDL | 七状态合法行、running lease、终态 key 复用 | 非法状态/控制、lease 错配、attempt/progress/checkpoint 错配、活动 key 冲突 |
| 删除动作 | fingerprint 随 Asset 删除；Job source 置空 | Source/Asset/Tag 受 RESTRICT 的删除被拒绝 |
| 事务 | 合法多步写入全成 | 后续失败时前序写入全部回滚 |

测试需要查询真实 `sqlite_schema`、`PRAGMA table_list`、`PRAGMA table_info`、`PRAGMA foreign_key_list` 和 `PRAGMA index_list/index_xinfo`，不能只断言 GRDB migration closure 被调用。实现者可以使用等价的 SQLite introspection API，但证据必须来自实际数据库；`table_list.strict` 或等价证据必须证明六张业务表均为 STRICT。

## 9. schema dump 证据格式

回传报告必须包含一份从新建 v001 数据库读取的确定性 schema dump：

- 按对象类型和名称稳定排序；
- 列出六张业务表、GRDB migration 表、七个命名业务索引及 SQLite 自动对象；
- 包含原始 `sqlite_schema.sql`，不得只给手工整理的表格；
- 单独列出已应用 migration ID；
- 单独列出 `journal_mode`、`foreign_keys` 与 `quick_check` 结果；
- 说明 dump 命令或测试如何生成，但不在仓库加入长期维护的脚本。

若输出过长，可作为实施报告附件；本切片不创建 `docs/STAGE-0-EVIDENCE.md`，该汇总文档在阶段 0 全部切片完成后生成。

## 10. 完成标准

本切片只有同时满足以下条件才可以申请评审：

- 官方 GRDB 版本范围和解析结果符合第 3.1 节，`Package.resolved` 已纳入版本控制；
- 生产 migration 列表只有 `v001_create_catalog_core`；
- 六张业务表、七个业务索引及全部规定约束准确存在；
- 文件型临时数据库的 WAL、foreign key、quick check、重开、future schema 与回滚测试通过；
- Source/locator 双向错配两例与 Photos fingerprint 一例（共三个跨表拒绝场景）以及多步事务回滚由真实数据库 Repository 测试证明；
- Domain 不导入 GRDB，Application/SwiftUI 不依赖具体数据库类型，Infrastructure 不导入 SwiftUI；
- 没有真实用户容器 I/O，没有 Job 行为、快照/恢复或启动集成；
- 原有 39 个测试全部继续通过，新增数据库测试全部通过，并报告实际总数；
- Debug build 成功，Swift 6 language mode 未回退；
- target 仍只有 `ImageAll` / `ImageAllTests`，共享 scheme 仍只有 `ImageAll`；
- entitlement 保持只有项目声明的 App Sandbox；
- `foundationReady` UI 和测试语义不变；
- `git diff --check HEAD^ HEAD` 无输出，并以 `git status --short --branch` 证明提交后工作区干净；
- 只创建一个独立本地切片 3 实现 commit，完成后工作区干净；
- 不配置 remote、不 push；
- 完成后停止，未进入切片 4。

## 11. Cursor 必须回传的证据

实施报告至少包含：

1. 开工前 HEAD、分支、干净工作区与“无预先 GRDB 草稿”的证据；
2. 新增/修改文件清单，每个文件对应的唯一职责；
3. GRDB 仓库、声明范围、解析版本、revision、产品和 `Package.resolved` 路径；
4. 生产 migration ID 列表及完整确定性 schema dump；
5. 六表数据字典逐项核对结果、七索引列表和 partial predicate；
6. WAL、foreign keys、quick check 的实际查询结果；
7. 第 7 节前六个行为簇各自的红灯测试名、失败原因与绿灯结果；
8. CHECK、FK、删除动作、partial unique、BINARY unique 和事务回滚的正反测试清单；
9. folder+photos locator、photos+file locator、Photos fingerprint 共三个 Repository 跨表拒绝场景；
10. 重开幂等、future schema 拒绝和失败 migration 回滚证据；
11. Domain/Application/Infrastructure import 与依赖方向检查；
12. 全套 `xcodebuild test`、Debug build 的命令、退出码、实际测试总数和结果摘要；
13. target、scheme、entitlement、UI 和阶段外功能是否变化；除 GRDB package 外预期均无变化；
14. 切片 3 commit、`git status --short --branch` 与 `git diff --check` 结果；
15. 已知限制、任何偏离、实现假设和未决问题。

不要求启动截图，因为本切片不改变 UI 或启动组装。包下载失败属于环境阻塞，不得用缓存不明的依赖或手工 vendoring 绕过。

## 12. 交回 Codex 后的评审门

Codex 将只做产品、架构、代码差异和证据评审，不替 Cursor 修改实现。重点检查：

- GRDB 依赖是否唯一、可复现且未越界；
- v001 是否与数据字典逐列一致，发布后不会需要原地改写；
- CHECK、FK、删除动作和 partial index 是否由真实反例证明；
- Unicode/BINARY 唯一性是否与已批准 Domain 规则一致；
- 跨表一致性和事务是否位于最小 Repository 边界；
- future schema 与 migration 失败是否结构化处理；
- 是否错误提前实现 Job、快照、锁、AppPaths 或 `CatalogReady`；
- schema dump、测试数、构建结果和 Git 边界能否独立复现。

只有切片 3 评审通过，才授权 Cursor 进入切片 4（持久化 Job 状态机）。此时阶段 0 仍处于实施中，不能标记为 Completed。
