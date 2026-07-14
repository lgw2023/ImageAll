# ImageAll 阶段 1 / 切片 1 Cursor 实施交接单

> 状态：Ready for implementation<br>
> 日期：2026-07-15<br>
> 实施者：Cursor CLI，仅 `Composer 2.5 Fast`<br>
> 产品与架构评审：Codex<br>
> 已批准功能基线：阶段 0 `main@892f4e29e1ebf492c1540c5a29d9c54abc05a78f`<br>
> Cursor 开工 HEAD：由调用任务中的 `<LAUNCH_HEAD>` 替换为包含本交接单的精确 Codex 文档 commit<br>
> 本轮唯一范围：`v002` 查询支持、图库查询端口、Inspector 详情读模型、人工标签目录/事务/Undo 前态

## 1. 开工结论

阶段 0 已通过 Codex 验收。项目所有者又于 2026-07-15 批准 `UI-001`～`UI-011`，并冻结 macOS 15+、Apple Silicon only、JPEG/PNG/HEIC/HEIF/TIFF/WebP 与本地自用签名。

本轮只实现这些批准界面未来所依赖的数据库查询和人工标签事务，不接触用户文件或 UI。结束时必须停止在切片 1，等待 Codex 独立复审。

## 2. 开工门与文档优先级

Cursor 开工前必须按顺序完整读取：

1. [`AGENTS.md`](../AGENTS.md)；
2. 本交接单；
3. [`STAGE-1-IMPLEMENTATION-SPEC.md`](./STAGE-1-IMPLEMENTATION-SPEC.md)，重点第 1～4、6 节；
4. [`STAGE-1-PRODUCT-UI-SPEC.md`](./STAGE-1-PRODUCT-UI-SPEC.md)，重点 UI-005、007、008；
5. [`STAGE-1-BACKEND-ARCHITECTURE.md`](./STAGE-1-BACKEND-ARCHITECTURE.md)，重点第 3、9、12、13 节；
6. [`STAGE-0-IMPLEMENTATION-SPEC.md`](./STAGE-0-IMPLEMENTATION-SPEC.md) 与已有数据库/Job 测试，只用于继承已批准契约；
7. [`.cursor/rules/codex-review-handoff.mdc`](../.cursor/rules/codex-review-handoff.mdc)；
8. [`LOCAL-TEST-DATA-SAFETY.md`](./LOCAL-TEST-DATA-SAFETY.md)。

若本交接单与阶段实施规格实质冲突，停止并报告，不得自行选择。

开工必须证明：

- 新 session；禁止 `--resume`；禁止 Cursor 子代理与 MCP；
- `system/init.model = Composer 2.5 Fast`；
- 当前为本地 `main`，HEAD 精确等于 `<LAUNCH_HEAD>`；
- 历史包含阶段 0 批准实现 `892f4e2`；
- 工作区除项目所有者已有未跟踪文件 `user/用户-前端想法.md` 外无其他变化；该文件只作批准规格的来源记录，本轮不得读取、修改、暂存或提交；
- 不得 reset、checkout、stash、clean 或覆盖任何已有文件；
- 不访问 `/Volumes/HDD2`，不运行会遍历该卷的命令。

## 3. TDD 顺序

按以下六簇逐簇红灯→最小绿灯；不得先写完整实现再补测试：

1. v002 migration 形状与 v001 sentinel 升级；
2. 页面请求、稳定 cursor 与三种排序；
3. 组合筛选和安全 search；
4. 网格/Inspector projection；
5. Tag 目录、选择聚合和批量事务；
6. Undo 前态恢复、完整回归和依赖检查。

每簇记录至少一个修正前失败测试及其失败原因。使用真实临时文件数据库，不用 in-memory database 替代 WAL/迁移/事务证据。

## 4. v002 精确范围

migration ID 固定为：

```text
v002_add_stage_1_catalog_query_support
```

`knownOrdered` 固定为 v001、v002。禁止修改 `V001CreateCatalogCoreMigration.swift` 的任何字节。

### 4.1 `asset.file_name`

追加 nullable `TEXT` 列。非 null 时必须：长度 > 0、不是 `.`/`..`、不含 `/`、不含 NUL。它是 file locator 的叶名称查询值，不是身份。v002 不回填或改写既有 `relative_path`。

### 4.2 六个命名索引

1. `asset_current_time_idx`：时间空标记、`coalesce(media_created_at_ms, media_modified_at_ms)`、id；partial current locator；
2. `asset_current_source_time_idx`：source ID、同一时间键、id；partial current locator；
3. `asset_current_file_name_idx`：`file_name COLLATE NOCASE`、id；partial current file 且 file name non-null；
4. `asset_generation_missing_idx`：source ID、last seen generation、id；partial current file；
5. `file_fingerprint_resource_id_idx`：resource ID、asset ID；partial resource ID non-null；
6. `file_fingerprint_sha256_idx`：SHA-256、asset ID；partial SHA non-null。

时间空标记：任一媒体创建/修改时间存在则 0，两者都空则 1。v002 不建新表、不建 FTS/缓存/prediction/undo history，不做表重建。

schema 测试必须使用真实 SQLite metadata 锁定列、索引 key/expression、排序 collation 与 partial predicate；不能只搜 Swift DDL 字符串。更新 snapshot/startup migration-prefix 测试，但不得弱化执行 migration 前的 future-schema 拒绝。

## 5. 查询端口

Application 层定义不含 GRDB 的 `Sendable` 请求、cursor、projection 与协议；Infrastructure 用 GRDB 实现。命名可贴合现有风格，语义不可改变。

### 5.1 页面请求

- sort：`newest`、`oldest`、`fileNameAscending`；
- cursor：与 sort 强绑定；nil 表示第一页；
- limit：1...200；0/201 结构化拒绝；
- 只返回 current locator；historical 不出现；
- Source disabled/unavailable/authorizationRequired 不使 current Asset 消失，Source state 随 projection 返回。

filter：

- source IDs：OR；
- 具体 `tagID + accepted/rejected` 条件；
- 多 Tag match：all/any；
- availability 集合；
- media UTI 集合；
- tag presence：any/tagged/untagged；tagged 只指至少一个 accepted，untagged 指 accepted 数为 0，rejected 不算已贴标签；
- 本地 search text。

search trim Unicode White_Space；空等于未过滤。非空搜索 file name、relative path、Source display name、已存在人工决定关系的 Tag display name。参数化 SQL，按字面量转义 `%`、`_` 和 escape 字符。不得将 search text、文件名或 relative path 写入错误消息/日志。

### 5.2 排序

- newest：已知时间先，`media_created_at_ms ?? media_modified_at_ms` DESC，asset ID DESC；
- oldest：已知时间先，同一时间 ASC，asset ID ASC；
- file name：non-null 先，`NOCASE` ASC，asset ID ASC；
- 未知时间在 newest/oldest 都放最后；
- cursor 带完整排序键与 asset ID，不能用 OFFSET；另一 sort 的 cursor 必须被拒绝。

### 5.3 projection

网格项：asset/source ID、Source display name/state、relative path/file name、UTI、媒体时间、宽高、availability、content revision、accepted/rejected 计数。

Inspector 详情：以上字段加 fingerprint size/mtime 与全部人工标签状态；本切片只返回既有 availability，不新增 per-asset 详细错误列。不得返回 bookmark、绝对路径、GRDB 类型或缓存 URL。不存在 ID 结构化拒绝。

## 6. 标签端口与事务

### 6.1 查询

- active Tag 默认按 normalized binary key + ID 稳定排序；可显式含 archived；
- 非空、去重选择集合的每个 Tag 返回 accepted/rejected/unknown 计数；三者之和等于选择数；
- 任一 asset 不存在则整体失败。

### 6.2 命令

交付 create、batch accepted、batch rejected、batch clear、create-and-apply、restore prior states。每批 1...10,000 个去重 asset IDs。

- 复用 Domain 名称与决定规则，不在 Infrastructure 重写；
- Tag 必须 active；全部 Asset 必须存在；
- 可以在同一 GRDB write transaction 内分块，禁止分事务提交；
- create-and-apply 任一后段失败，Tag 和决定全回滚；
- 成功批量命令返回每个 Asset 的 previous unknown/accepted/rejected；
- restore prior states 是无状态单事务端口；切片 7 的 Application presentation 才负责只保留最近一次成功 mutation 并使旧 Undo 失效；
- Undo 不跨重启，不增加 token registry 或持久化表；本轮不做 Undo UI。

错误至少覆盖 invalid limit、cursor mismatch、not found、empty/too-large selection、archived tag、duplicate normalized tag、invalid name 与 persistence failure，且不包含用户数据或 SQL。

## 7. 必须覆盖的测试

### 7.1 Migration/schema

- fresh v001→v002、幂等重开、future schema 前置拒绝；
- v001 文件库带 Source/Asset/Tag/decision sentinel，升级后事实逐项保留；
- file name 正例与 empty/dot/dotdot/slash/NUL 反例；
- 六索引 sqlite metadata introspection；
- v001 schema SQL 与批准版本逐字一致；
- 失败 migration DDL 回滚。

### 7.2 Query

- current vs historical，四种 Source state；
- 每个 filter 单项正反例和组合矩阵；
- Tag accepted/rejected、ALL/ANY、tagged/untagged；
- 四字段 search，literal `%`/`_`/escape，参数化注入反例；
- 三种排序，duplicate key/null time/NOCASE collision；
- 多页遍历恰好覆盖全集，无重复/跳项；cursor sort mismatch；
- grid projection 计数，Inspector not-found。

### 7.3 Tag transaction

- Domain Unicode normalization 与数据库并发 duplicate 防线；
- accepted/rejected/clear；三态聚合；
- archived/missing/too-large/SQL failure 全回滚；
- 跨 bind limit 的分块仍单事务；
- create-and-apply 原子性；
- prior-state restore 恢复 unknown/accepted/rejected 混合前态；UI 级旧 token 失效留到切片 7。

### 7.4 回归

- 全部 Debug tests；
- Debug build；
- `git diff --check`；
- Swift 6、target、scheme、entitlement、Package.resolved、Composition Root、启动 UI 语义不变；
- Domain/Application 无 GRDB import，App/SwiftUI 无具体数据库依赖；
- 无真实用户容器或 `/Volumes/HDD2` I/O。

## 8. 允许与禁止修改

允许：

- Domain/Application 中切片 1 所需的纯值、错误、端口和最小规则；
- Infrastructure/Database 的 v002、query/tag repository；
- 对应 `ImageAllTests` 与必要 Xcode 文件引用；
- 既有 migration history/snapshot/startup 测试中因 v002 必须更新的精确期望。

禁止：

- 修改 Codex 文档、任务记录或 `user/`；
- 修改 v001、GRDB 版本、Package.resolved；
- entitlement、privacy manifest、NSOpenPanel、bookmark、文件枚举、Image I/O、FSEvents、缩略图、缓存文件；
- SwiftUI、Composition Root、Job scheduler、`foundationReady`/`CatalogReady`；
- v003、切片 2+ 占位、AI/Photos/Smart Collection/自动化；
- `/Volumes/HDD2`、真实 Application Support/Caches；
- push、amend、history rewrite。

## 9. 验收和本地 commit

至少执行：

```bash
xcodebuild -scheme ImageAll -destination 'platform=macOS' -configuration Debug test
xcodebuild -scheme ImageAll -destination 'platform=macOS' -configuration Debug build
git diff --check
```

从测试输出或 `.xcresult` 报告准确测试总数，不硬编码沿用 268。必要时可设置独立 DerivedData，但不能用另一个 scheme/target 代替。

通过后创建一个窄范围本地 commit：

- author/committer：`Cursor Agent <cursoragent@cursor.com>`；
- subject：`feat(cursor): add stage 1 catalog query foundation`；
- trailer：`Agent-Role: implementation`；
- 不含 `Co-authored-by`；
- 不暂存 `user/用户-前端想法.md`；
- 不 push。

交付后停止并按 `.cursor/rules/codex-review-handoff.mdc` 输出中文复审材料，明确未进入切片 2。

## 10. Codex 重点复审点

1. v001 是否零修改，v002 是否只有批准列和六索引；
2. cursor 是否严格 keyset、未知值排序稳定、无 OFFSET；
3. disabled/unavailable Source 的 current Asset 是否仍保留；
4. search 是否参数化且 literal wildcard 正确；
5. Tag 批量分块是否仍在单一事务，create-and-apply/Undo 是否无半事实；
6. 是否出现 entitlement、文件 I/O、UI 或切片 2+ 越界。
