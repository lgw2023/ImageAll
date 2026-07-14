# Cursor 交接单：阶段 0 / 切片 6——安全启动集成

> 状态：Authorized for implementation，等待全新 Cursor CLI session 执行
> 日期：2026-07-14
> 上一验收门：阶段 0 切片 5 已由 Codex 复审通过，批准实现截至 `main@562f778`
> 权威上位规格：[STAGE-0-IMPLEMENTATION-SPEC.md](./STAGE-0-IMPLEMENTATION-SPEC.md)
> 安全边界：[LOCAL-TEST-DATA-SAFETY.md](./LOCAL-TEST-DATA-SAFETY.md)
> 本轮范围：AppPaths、应用容器目录、OS advisory process lock、安全数据库 bootstrap/migration、崩溃恢复调用、启动状态与 Composition Root/UI 接线

## 1. 授权范围和停止位置

本切片实现阶段 0 最后一条纵向链：

```text
解析容器路径 → 创建阶段 0 所需目录 → 取得独占进程锁
→ 只读检查正式库 migration history
→ 按需创建新库或生成迁移前快照并迁移工作副本
→ 验证并发布正式库 → 恢复遗留 running Jobs
→ 发布 CatalogReady，并由运行时持续持有数据库与锁
```

完成后必须停止并交回 Codex。不得进入阶段 1，不得实现文件夹选择、security-scoped bookmark、PhotoKit、真实扫描 Job handler、缩略图、hash、OCR、embedding、模型、标签产品界面或快照保留策略。

切片 6 只建立“允许以后调度”的 readiness gate。当前没有生产扫描 handler，因此不得为了证明调度而创建空 worker、定时器或伪 Job。

## 2. 不可变约束

1. 不修改已经发布的 `v001_create_catalog_core`；如果发现 schema 缺陷，停止并报告，不得原地改 migration。
2. 不改变 `foundationReady == true` 的既有含义。它仍表示 SwiftUI/Composition Root 工程底座成立；目录库状态由新的封闭启动状态表达。
3. 未取得 OS advisory lock 的实例不得打开、检查或迁移正式数据库。
4. migration 不能在正式数据库路径原地执行。新库和旧 schema 都只在同卷临时候选/工作副本迁移，验证成功后才发布或替换。
5. `CatalogReady` 只能在正式库最终打开且 `recoverInterruptedRunningJobs()` 成功返回后发布。
6. 路径、建目录、锁、数据库、snapshot、migration 和 recovery I/O 不得运行在 UI 主 actor；只有展示状态变更回到 `MainActor`。
7. 任何失败不得静默创建另一份空库，不得启动调度，不得把原始路径、SQL、Photos ID、bookmark 或底层错误文本展示到 UI/日志。
8. 自动化测试只使用每测试独立临时目录；不得访问真实 Application Support 容器或 `/Volumes/HDD2`。

## 3. AppPaths 契约

### 3.1 分层

- Application 层定义可注入的路径值/端口，不导入 GRDB、Darwin 或 SwiftUI；
- Infrastructure 提供 Foundation 系统解析器；
- Composition Root 只请求一个完整 `AppPaths`，不能散落拼接子路径；
- 测试提供临时根目录实现，不调用真实容器 API。

正式布局固定为：

```text
Application Support/
├── Catalog/
│   └── ImageAll.sqlite
├── Backups/
└── Runtime/
    └── catalog.lock

Caches/
└── （阶段 0 只解析 URL；没有实际缓存时不创建空目录）
```

本切片只创建确实会使用的 `Catalog/`、`Backups/` 和 `Runtime/`。系统实现使用 Foundation 的域目录 API，让 App Sandbox 返回应用容器内位置；不得硬编码 `/Users/.../Library`、bundle container UUID 或当前用户名。

参考：

- [Apple App Sandbox：容器位置由系统 API 返回](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [Foundation `URL.applicationSupportDirectory`](https://developer.apple.com/documentation/foundation/url/applicationsupportdirectory)
- [Apple：Application Support 用于长生命周期支持数据](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively)

### 3.2 路径失败

域目录解析、类型检查或建目录失败必须返回结构化启动失败。已有路径如果不是目录要拒绝；不得删除、覆盖或“修复”未知用户内容。正式数据库父目录、snapshot 目录和工作副本必须在同一文件系统卷，不能跨卷降级为 copy-then-delete。

## 4. 进程级独占锁

在 `Runtime/catalog.lock` 上使用 Darwin `flock` 风格的 advisory lock：打开文件描述符后以 `LOCK_EX | LOCK_NB` 非阻塞取得锁。锁的事实是内核对打开文件描述符的锁定，不是 lock 文件是否存在。

最小契约：

- 第一个实例取得一个不可复制的 ownership token；token 持有文件描述符；
- 第二个实例收到明确的 `alreadyRunning` 结果，不等待、不打开正式库；
- 打开/权限等 I/O 失败与正常 contention 分开；
- token 显式释放或进程退出后，另一个实例可以取得锁；残留 lock 文件不能阻止启动；
- ready runtime 必须强引用 token，直至正常关闭或进程结束；
- bootstrap 在取得锁后失败时，先关闭所有数据库连接，再释放 token。

测试必须真实使用临时目录中的两个 lock owner，不能只用布尔 mock 证明 `flock` 行为。可注入 seam 只用于 I/O 失败与调用顺序测试。

参考：[Apple archived `flock(2)` man page](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html)。

## 5. 启动展示和运行时所有权

### 5.1 封闭状态

增加一个可观察、封闭且不泄露敏感信息的目录库启动状态，至少能区分：

- `catalogStarting(stage)`：`paths`、`lock`、`catalog`、`recovery` 等稳定阶段码；
- `catalogReady`；
- `anotherInstanceRunning`；
- `catalogUnavailable(reason)`：稳定、安全的原因码，不携带底层 `Error.localizedDescription`。

失败原因至少要能把路径/锁 I/O、future schema、integrity、空间不足、snapshot、migration/publication、最终打开和 Job recovery 分开。空间不足允许携带非负 `requiredBytes` 估算值；不得携带文件路径。

阶段 0 UI 只需显示产品名、既有 `foundationReady` token 和一个稳定的目录库状态 token。不要新增恢复按钮、目录选择器、alert、调试路径或正式产品导航。

### 5.2 生命周期

启动 presentation/model 在 `MainActor` 更新 SwiftUI 状态；真正 bootstrap 在非主 actor 执行。不要用 `Task {}` 后仍继承 `MainActor` 的方式执行同步数据库 I/O；实现与测试需证明阻塞工作不在 main thread/actor 上。

成功返回的运行时对象至少拥有：

- 最终打开的 `CatalogDatabase`；
- 独占 lock token；
- 已完成恢复的 `JobQueue`。

只有 Composition Root/应用生命周期对象可以长期持有该 runtime。正常关闭 seam（至少供测试使用）必须先关闭数据库，再释放锁。Swift 6 concurrency 检查必须通过，不得用 `@unchecked Sendable` 隐藏未证明的共享可变状态。

参考：

- [The Swift Programming Language: Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
- [Apple: Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Apple `MainActor`](https://developer.apple.com/documentation/swift/mainactor)

## 6. 数据库 bootstrap 决策表

取得锁之后，先以不会运行 migration 的短生命周期检查连接读取 `grdb_migrations`、执行 `quick_check` 并关闭。启动代码不得直接对正式路径调用当前会自动 `migrate()` 的 convenience open。

| 正式库状态 | 必须行为 | 禁止行为 |
|---|---|---|
| 文件不存在 | 在 `Catalog/` 同目录创建唯一候选；候选上创建 v001、quick check、关闭并清除 sidecar；同卷原子发布；再最终打开 | 在正式路径直接创建/迁移；创建 pre-migration snapshot |
| 已是当前完整 migration prefix | 不创建 snapshot/工作副本；最终打开、再次验证 | 无变化也复制或替换数据库 |
| 已知旧 prefix（含没有 `grdb_migrations` 的空 SQLite） | 检查空间；对原库创建已验证 pre-migration snapshot；关闭源库；从 snapshot 建工作副本、仅在副本 migration；通过切片 5 的安全替换能力发布 | 原地 migration；snapshot 失败后继续；跳过保留原库的替换协议 |
| 包含未知 migration 或不是已知有序 prefix | 关闭检查连接，发布 `catalogUnavailable(schemaUnsupported)` | downgrade、改写 migration 表、创建空库或尝试 recovery |
| quick check 失败 | 关闭连接并发布 integrity failure | migration、snapshot、替换或 recovery |

正式“当前 schema 打开”入口必须验证 migration history 恰好等于 `CatalogMigrationID.knownOrdered`、FK 已启用、quick check 为 `ok`，且不得运行新 migration。允许保留现有测试/fixture 使用的便捷 open，但正式启动管线必须走安全入口。

### 6.1 新库候选发布

- 候选文件使用注入的 operation UUID 命名，和正式库同目录；
- publication 前候选是当前 schema、DELETE journal、无 `-wal`/`-shm`、quick check 通过；
- 正式路径若在过程中突然出现，拒绝覆盖；
- 原子 rename/publish 失败时正式路径仍不存在；候选只做 best-effort 清理并报告失败；
- publication 后再以正式 current-schema open 打开，不能把候选连接冒充正式 runtime。

### 6.2 旧 schema 迁移

迁移前 snapshot 必须调用切片 5 已实现的 `createPreMigrationSnapshot`，snapshot ID、时间和 app version 由可注入依赖提供。生产 app version 从 bundle 版本元数据取得，测试不得依赖真实 bundle。

迁移工作副本和带 backup item 的替换复用切片 5 已通过的验证/替换 primitive，不复制一套弱化流程。migration、候选验证、替换前或替换后验证失败时，必须符合切片 5 的回滚/人工干预错误语义，且不能发布 ready。

### 6.3 空间门

在旧 schema snapshot 之前执行可注入的容量检查。最小估算契约为：

```text
sourceFootprint = 主库及当时存在的 -wal/-shm 正规文件字节数之和
requiredAdditionalBytes = 2 × max(sourceFootprint, 1 MiB) + 64 MiB
```

它覆盖一份 snapshot、一份 migration work copy 和阶段 0 的固定余量。算术溢出、容量不可查询或可用空间小于估算值时阻止升级；UI 只暴露估算字节数，不暴露路径。测试用容量 provider 强制覆盖不足和恰好足够边界；不得真的填满磁盘。

## 7. Job 恢复和 readiness gate

最终正式库成功打开后，用同一 `CatalogDatabase` 构造 `GRDBJobQueue` 并调用 `recoverInterruptedRunningJobs()`。顺序固定为：

```text
final open success → recoverInterruptedRunningJobs success → retain runtime → CatalogReady
```

反例必须证明：

- migration、final open 或 recovery 任一失败都不发布 ready；
- recovery 失败时不 claim Job、不启动 handler，并关闭数据库/释放锁；
- 未取得 lock 的实例数据库 open 次数为 0；
- `CatalogReady` 发布时可以立即通过 runtime 读取 current migration history，且 lock 仍由本实例持有。

本切片不调用 `claimNext`，不创建 scheduler loop。

## 8. TDD 测试矩阵

先提交能失败的测试，再写最小实现。测试文件可按职责拆分，但不要为了测试建立生产抽象大全。

| 簇 | 必须覆盖的正例 | 必须覆盖的反例 |
|---|---|---|
| AppPaths | 注入根得到精确布局；只创建 Catalog/Backups/Runtime | 文件占据目录位置；解析/建目录失败结构化返回；不创建无用 cache |
| advisory lock | 首实例成功；释放后第二实例成功；残留 lock 文件无影响 | 同时第二实例 `alreadyRunning`；I/O failure 不等同 contention |
| ordering | paths→dirs→lock→inspect→prepare→final open→recover→ready | lock 前数据库调用、recover 前 ready、失败后继续均被调用记录拒绝 |
| 新库 | 只在候选迁移，验证后原子发布，最终 formal open | 候选 migration/quick check/publish 失败不留下正式空库；竞争出现正式路径不覆盖 |
| 当前库 | 不创建 snapshot、不替换、最终打开后恢复 | integrity/future history 不 recovery、不 ready |
| 旧 schema | snapshot 后从工作副本升级，原事实保留，最终 current | 空间不足、snapshot/migration/replacement 失败保持原库且不 ready |
| 运行时 | ready 同时持有 DB+lock；显式 close 后可重新加锁 | recovery 失败关闭 DB、释放锁；第二实例 formal open 次数为 0 |
| 展示 | starting→ready；`foundationReady` 仍为 true | 安全失败码不包含底层路径/SQL/error text |
| concurrency | UI 状态更新在 MainActor，bootstrap 工作线程非 main | 测试捕获 migration/recovery 在 main thread 即失败 |
| 回归 | 原 224 项及新增测试全绿 | 不新增 entitlement/target/package，不改 v001 |

数据库集成测试必须使用真实临时文件库证明新库、当前库、旧 schema、future schema 和 recovery；纯 mock 只用于调用顺序与故障注入。

## 9. 手工 smoke evidence

自动化全绿后，运行 Debug app 做最小非破坏 smoke：

1. 记录 build product、bundle identifier 和启动进程；
2. 记录 UI 或安全日志状态从 starting 到 `CatalogReady`；
3. 验证 app 只在自己的 sandbox container 创建 `Catalog/ImageAll.sqlite`、`Backups/` 和 `Runtime/catalog.lock`，不打印完整容器绝对路径到交付日志；
4. 在不删除第一实例数据的前提下启动第二实例，证明其进入 `anotherInstanceRunning`，且第一实例仍为 ready；
5. 正常终止两个测试实例，不能删除或重置已有 container 数据。

如果本机隐私/UI 自动化权限不允许抓取文字，用进程、bundle、结构化安全状态日志与自动化 lock 集成测试组合举证，不伪造截图。

本 smoke 首次允许应用自己的正式容器 I/O，但不是容器清理授权。不得运行 `rm`、reset 或 destructive fixture 命令。不得访问 `/Volumes/HDD2`，包括不得列目录或遍历 `.photoslibrary`。

## 10. 架构和工程边界

- Domain 不导入 GRDB、SwiftUI、Darwin；
- Application 不依赖 `DatabasePool`、`FileManager.default` 或具体 `flock`；
- Infrastructure 不导入 SwiftUI；
- App/Composition Root 可以组装 Infrastructure，但 View 不直接创建数据库、lock 或 filesystem resolver；
- 不新增第三方依赖、target、scheme、entitlement；
- Swift 6 language mode、macOS 15 target 和 GRDB 7.11.1 锁定不变；
- 只改与切片 6 直接相关的文件，不重构已通过切片 1–5 的无关实现。

## 11. 验收命令和提交

至少执行：

```bash
xcodebuild -scheme ImageAll -destination 'platform=macOS' -configuration Debug test
xcodebuild -scheme ImageAll -destination 'platform=macOS' -configuration Debug build
git diff --check
git status --short --branch
```

Cursor 只提交实现、测试和必要 Xcode project 引用，使用：

```bash
git -c user.name='Cursor Agent' -c user.email='cursoragent@cursor.com' commit \
  -m 'feat(cursor): integrate safe catalog startup' \
  -m 'Agent-Role: implementation'
```

不得把 Codex handoff/任务记录改进 Cursor commit，不 push、不 amend、不 squash、不改写历史。

## 12. 交回 Codex 的证据

按 [`.cursor/rules/codex-review-handoff.mdc`](../.cursor/rules/codex-review-handoff.mdc) 输出完整复审材料，并额外包括：

1. `system/init.model = Composer 2.5 Fast` 与新 Cursor session ID；
2. 精确开工 HEAD、交付 commit、分支、最终工作区；
3. 红灯→绿灯测试簇及最终测试总数；
4. AppPaths 正式布局与所有测试临时根证据；
5. 两实例真实 `flock` 行为与“未获锁 formal DB open = 0”证据；
6. 新库、当前库、旧 schema、future schema 四条真实文件数据库路径的测试证据；
7. 空间不足、snapshot/migration/final open/recovery 失败均不 ready 的反例；
8. UI 主线程不做 blocking I/O 的实现与测试证据；
9. 手工 smoke 证据及明确的 `/Volumes/HDD2` 零访问声明；
10. `git show -s --format='%an <%ae>%n%s%n%(trailers)' HEAD` 原样输出；
11. 依赖/target/scheme/entitlement/v001 均未变化；
12. 停止于阶段 0 切片 6，未进入阶段 1。

Codex 会独立检查 diff、作者归属、完整测试、Debug build、安全启动顺序和容器边界。未通过时只允许续接本任务 session 做窄范围返修；通过后该 session 立即退役。
