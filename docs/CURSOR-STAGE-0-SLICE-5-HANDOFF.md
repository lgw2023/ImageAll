# ImageAll 阶段 0 / 切片 5 Cursor 实施交接单

> 状态：Ready for implementation  
> 日期：2026-07-14  
> 实施者：Cursor CLI（仅 `Composer 2.5 Fast`）  
> 产品与架构评审：Codex  
> 已批准功能基线：`main@e207180`  
> Cursor 开工基线：包含本交接单、由 Codex 调用任务明确给出的最新本地 `main` HEAD  
> 本轮范围：目录库操作快照、manifest 校验、旧 schema 恢复工作副本、带 backup item 的原子替换与失败回滚；不包含 AppPaths、进程锁或 App 启动集成

## 1. 交接结论

阶段 0 切片 4 已通过 Codex 独立复审。当前批准基线包含 SwiftUI 空壳、纯 Domain 规则、GRDB 7.11.1、不可变 `v001_create_catalog_core`、最小 Catalog Repository，以及持久化 Job 状态机；177 项测试与 Debug build 已通过。

Cursor 现在获准实施切片 5：为目录库建立同机操作快照和手动恢复核心，使 live WAL 数据库能够在并发读写期间生成一致、经校验且只有完成后才发布的快照；使恢复只在工作副本上迁移，并以 Foundation 的同卷安全替换保留原活动库；替换后验证失败时自动回滚并隔离失败候选。

本轮结束后必须停在切片 5 并交回 Codex 复审。不得进入切片 6 的正式 AppPaths、OS advisory process lock、Composition Root 数据库装配、启动 migration orchestration、遗留 Job 恢复调用或 `CatalogReady` UI。

## 2. 文档优先级与开工门

Cursor 开工前必须完整阅读，优先级从高到低：

1. [`AGENTS.md`](../AGENTS.md)：角色、全新 Cursor 会话、模型、Git 与真实照片保护规则；
2. 本交接单：切片 5 的精确实现范围、恢复状态机与验收门；
3. [`STAGE-0-IMPLEMENTATION-SPEC.md`](./STAGE-0-IMPLEMENTATION-SPEC.md)：重点是第 3.3、4.4、7、8、9.5 节；
4. [`ARCHITECTURE.md`](./ARCHITECTURE.md)：重点是第 9.3、15、17.2 节；
5. [`CURSOR-STAGE-0-SLICE-4-HANDOFF.md`](./CURSOR-STAGE-0-SLICE-4-HANDOFF.md)：只用于理解已批准的数据库与 Job 边界，不是本轮任务单；
6. [`LOCAL-TEST-DATA-SAFETY.md`](./LOCAL-TEST-DATA-SAFETY.md)：自动化只用临时目录与合成数据库。

若本交接单与阶段规格存在实质冲突，必须停止并报告，不得自行选择。开工时必须证明：

- `system/init.model = Composer 2.5 Fast`，并回传全新的 Cursor session ID；
- 开工 HEAD 精确等于 Codex 调用任务给出的文档 commit，历史包含批准功能基线 `e207180`；
- 分支为本地 `main`，工作区干净；若不干净，逐项说明来源，禁止 `reset`、`checkout`、`stash`、`clean` 或覆盖；
- 不恢复任何切片 4 或更早的 Cursor 会话；
- 不访问 `/Volumes/HDD2`，不读取或遍历真实 Photos Library 与年份目录。

本轮不得修改 `v001_create_catalog_core`。若实现发现已批准 schema 或 Catalog Database API 无法满足本契约，先停止并报告；没有产品批准不得原地改 migration，也不得自行增加 v002。

## 3. 关键技术决策

### 3.1 快照必须使用 SQLite online backup

- live 数据库由现有 `DatabasePool` 提供；快照使用 GRDB 7.11.1 的 `DatabaseReader.backup(to:pagesPerStep:progress:)`，它封装 SQLite online backup API；
- 禁止对打开的正式数据库主文件直接 `copyItem`、`Data(contentsOf:)`、shell `cp` 或只复制 `.sqlite` 而忽略 WAL；
- 目标使用独立的文件型数据库连接，整个 backup 期间不能被其他代码访问；
- backup 可分步执行以便测试和未来进度/取消，但本切片不增加产品进度 UI；
- 并发写可能包含也可能不包含在最终快照中，验收要求是单一一致提交视图，不要求“包含 backup 期间最后一次写入”；
- migration 列表必须从 backup 目标数据库读取，不能在 source 上另行读取后拼接，避免 manifest 与快照跨越不同提交点。

SQLite 官方说明 online backup 完成后目标是 source 的一致快照；GRDB 7.11.1 也明确允许 `DatabasePool` 在 backup 期间继续并发写入。实现应使用锁定版本公开 API，不直接引入新的 SQLite C wrapper。

### 3.2 快照与可移植导出是不同产品

本切片只实现同一 Mac、同一应用容器中的操作快照。它可以包含目录库中已有的 opaque security-scoped bookmark BLOB，因为目的是完整恢复目录库；manifest 本身不得包含 bookmark、路径、Photos identifier、payload 或任何数据库事实明文。

不实现可移植 JSON/JSONL 导出，不承诺跨设备恢复，也不把操作快照解释成磁盘灾难备份。

### 3.3 文件替换必须使用 Foundation 的安全替换语义

- 恢复候选必须位于正式数据库同一卷；候选工作目录放在正式数据库父目录的唯一隐藏临时目录中；
- 替换使用 `FileManager.replaceItem(at:withItemAt:backupItemName:options:)`，提供唯一 backup item 名，并带 `.withoutDeletingBackupItem`；
- Apple 文档说明该 API 以避免数据丢失的方式替换，并要求新旧项目位于同一 volume；
- 禁止“删除正式库，再 move/copy 候选”的实现；
- 成功恢复仍保留替换前数据库 backup item，切片 5 不做保留数量或清理策略。

## 4. 分层、职责与最小交付

### 4.1 允许的生产职责

生产实现保持在 `Infrastructure/Database`，可按现有风格拆为以下职责，文件名不强制：

```text
Snapshot manifest value + codec
Snapshot validator / catalog
Online snapshot creator
Closed-database restore / replacement coordinator
Narrow file replacement and post-replace validation seams
```

依赖规则：

- 允许 Foundation、CryptoKit 与现有 GRDB；CryptoKit 是系统框架，不新增 package；
- 不把 GRDB、SQL、`DatabasePool`、文件替换细节暴露给 Domain 或 SwiftUI；
- 不把 snapshot/restore 伪装成 Job handler；恢复要求调度已停止，不能由普通队列任务替换自己正在使用的数据库；
- 不新增 module、target、scheme、entitlement、package 或 executable helper；
- 不修改 Job 状态机、Catalog Repository 领域语义和 UI。

为了可靠测试 replacement 之后的失败补偿，允许在 Infrastructure 内增加一个窄的文件替换 seam 和一个窄的 post-replace validation seam。不得借此建立通用虚拟文件系统、依赖注入框架或生产 fake。

### 4.2 本轮必须交付

1. `format_version = 1` 的 manifest 编解码与封闭校验；
2. 从现有 `DatabasePool` 创建一致 snapshot；
3. 临时目录写入、quick check、hash/size 校验与最终目录发布；
4. 只返回已发布且通过静态完整性校验的 snapshot 列表；
5. 手动 snapshot 与 migration 前 snapshot 的同一核心入口；
6. snapshot → 同卷恢复工作副本；
7. snapshot migration history 与数据库真实 history 的交叉校验；
8. 旧 known-prefix schema 只在工作副本 migration；future schema 拒绝；
9. WAL checkpoint/close/sidecar 边界；
10. 带 retained backup item 的正式库替换；
11. post-replace reopen/quick check 失败时的自动回滚与 quarantine；
12. 使用真实临时文件数据库的正反集成测试。

### 4.3 明确不做

- 不实现正式 `AppPaths`，所有路径由调用者注入；
- 不访问真实 Application Support 容器；
- 不实现或伪造进程级独占锁；恢复核心的调用前提由切片 6 组装并强制；
- 不从 Composition Root 调用 snapshot/restore，不改变 App 启动；
- 不调度自动每日 snapshot，不实现“保留最近三份”的清理；
- 不新增恢复窗口、按钮、菜单、alert 或 `CatalogReady`；
- 不实现真实数据库升级流程或新增 migration；只证明工作副本可运行当前 migrator；
- 不实现可移植导出/导入、云备份、加密、压缩或外置备份；
- 不扫描文件夹、不接入 PhotoKit、不读取任何真实照片。

## 5. Snapshot 目录与 manifest v1

### 5.1 目录形状

调用者注入 `backupsDirectoryURL`。本轮固定：

```text
Backups/
├── <snapshot-id>.tmp/       # 创建中；永不列为可恢复项
│   ├── ImageAll.sqlite
│   └── manifest.json
└── <snapshot-id>/           # 只有完整校验后才发布
    ├── ImageAll.sqlite
    └── manifest.json
```

- snapshot ID 是小写规范 UUID；目录名、manifest `snapshot_id` 必须完全一致；
- 数据库文件名固定为 `ImageAll.sqlite`，manifest 不得把任意路径当作文件名；
- manifest 文件名固定为 `manifest.json`；
- 创建前 `.tmp` 与最终目录都必须不存在。碰撞返回结构化错误，不能删除或复用已有目录；
- 失败只清理由本次调用成功创建的 `.tmp`，不得清理未知目录；
- 最终发布是同一 `Backups` 目录内的 directory rename；rename 失败时最终目录不得被报告为成功；
- `.tmp`、非 UUID 目录、缺失 manifest 的目录永不进入可恢复列表。

### 5.2 JSON 精确字段

manifest 使用 UTF-8 JSON，v1 必须包含以下字段：

| JSON key | 类型 | 约束 |
|---|---|---|
| `format_version` | integer | 必须恰好为 `1` |
| `snapshot_id` | string | 小写规范 UUID，等于目录名 |
| `created_at_ms` | integer | 注入时钟产生的 UTC Unix epoch milliseconds，必须非负 |
| `app_version` | string | trim 后非空，由调用者注入；不在 Infrastructure 直接猜测 Bundle/UI 值 |
| `applied_migrations` | array of string | 无重复、顺序与 `CatalogMigrationID.knownOrdered` 的某个前缀一致 |
| `database_filename` | string | 必须恰好为 `ImageAll.sqlite` |
| `database_bytes` | integer | 必须 > 0，等于关闭后的文件实际字节数 |
| `database_sha256` | string | 恰好 64 个小写十六进制字符，等于关闭后的数据库 SHA-256 |

编码输出使用 snake_case。字段顺序与 JSON 空白不是协议；测试应 decode 后比较，不用整段字符串快照锁死编码器格式。未知额外字段可忽略，但未知 `format_version` 必须拒绝。

`applied_migrations` 必须同时满足：

1. manifest 列表是当前应用 known migrations 的有序前缀；
2. 候选数据库真实 `grdb_migrations` 内容也是相同前缀；
3. 两者逐项完全相等。

任一未知 migration、非前缀组合、重复或 manifest/database 不一致都拒绝。错误不应输出原始 SQL、bookmark 或数据库内容。

### 5.3 静态与数据库校验

snapshot discovery 的静态校验至少包括：目录/ID、JSON、固定文件名、普通文件且非 symbolic link、字节数、SHA-256、migration 列表形状，以及无同名 `-wal`/`-shm` sidecar。静态校验失败的最终目录不返回为可恢复项。

创建和真正恢复还必须对数据库执行 `PRAGMA quick_check` 并读取真实 migration history。已发布 snapshot 的数据库文件不得为了“验证”被原地 migration，也不得把新 sidecar 或其他产物留在 snapshot 目录；恢复时应先复制到工作副本，再做数据库级校验和 migration。

## 6. Snapshot 创建状态机

创建顺序固定如下：

1. 校验注入的 snapshot ID、timestamp、app version 和目标目录碰撞；
2. 只创建本次 `<id>.tmp/`；
3. 在 temp 内打开独占目标数据库连接；
4. 从 live `DatabasePool` 使用 GRDB online backup 写目标；
5. 在 backup 目标连接上执行 `PRAGMA quick_check`，读取并校验真实 applied migrations；
6. 关闭目标数据库连接；关闭失败视为创建失败；
7. 确认 temp 数据库没有 `-wal` / `-shm`；若干净关闭后仍残留，只能在所有目标连接确已关闭后清理由本次创建的目标 sidecar；
8. 对关闭后的单一数据库文件读取字节数并流式计算 SHA-256；不得把整个未来大库无界读入内存；
9. 写 manifest；再 decode manifest 并复核固定字段、size 与 hash；
10. 将整个 `<id>.tmp/` rename 为 `<id>/`；
11. 返回 descriptor。只有此时可报告成功。

任一步失败：关闭已创建连接，删除本次 `.tmp`，保留 live 数据库和已有 snapshots 不变。不能发布半目录，不能把失败 temp 返回给列表。

手动 snapshot 和 migration 前 snapshot 必须复用同一个创建 primitive；允许两个语义清晰的入口，但不得复制两套文件流程。切片 5 只证明 migration 前入口能生成合格 snapshot，切片 6 才把它接到正式 migration orchestration。

## 7. 并发一致性验收

必须用真实 `DatabasePool` 和足够跨越多个 SQLite page 的合成数据证明 backup 期间并发写入：

1. 以小 `pagesPerStep` 开始 snapshot；
2. 在第一个未完成 progress 回调处用测试同步原语证明 backup 已开始；
3. 从同一个 pool 的另一写连接提交一组具有关联约束的事实，例如 source/asset/tag/decision 的完整事务；
4. 释放 backup 继续完成；
5. 打开 snapshot 工作副本验证 quick check、FK/事实关系和 migration history；
6. 允许并发事务整体存在或整体不存在，但禁止半事务、损坏或 backup error。

测试不能只在 backup 前后各写一次、不能只用 mock、不能断言并发写必然被包含。

## 8. 恢复前提与工作副本

### 8.1 调用前提

切片 5 的恢复核心只接受调用者注入的正式数据库 URL 与 snapshot URL。调用前提必须在 API 文档和测试命名中明确：

- 调度已停止；
- 当前进程拥有独占目录库访问权；
- 不存在并发 Catalog reader/writer；
- live `DatabasePool` 已完成 barrier、`TRUNCATE` checkpoint 并显式 `close()`。

切片 5 可以提供一个作用于现有 `CatalogDatabase` 的最小 `checkpointAndCloseForReplacement` 生命周期操作，以固定 `TRUNCATE` checkpoint 与显式 close 的顺序；它不能声称取得了进程锁。切片 6 负责在调用它前停止调度并持有 OS advisory lock。

若 checkpoint、close 或 sidecar 收敛失败，必须在 replacement 前终止。不得在还有活动连接时删除 WAL/SHM。SQLite 明确把 WAL 视为数据库持久状态的一部分；只有成功 checkpoint、关闭所有连接后，才能处理残留 sidecar。

### 8.2 恢复工作副本

正式库替换前固定执行：

1. 静态校验 snapshot manifest、size、hash、ID、文件名与 sidecar；
2. 在正式数据库父目录创建唯一 `.restore-<operation-id>.tmp/`，保证与正式库同卷；
3. 把已关闭的 snapshot 数据库复制到工作副本；这是复制稳定 snapshot，不是复制 live WAL 数据库；
4. 只打开工作副本，执行 quick check，读取真实 migrations 并与 manifest 完全比较；
5. 若是当前 schema，保持；若是当前 known migrations 的旧前缀，只在工作副本运行现有 `CatalogDatabase` migrator；
6. migration 后再次 quick check，并确认 applied migrations 等于当前完整 known list；
7. 对工作副本执行 `TRUNCATE` checkpoint、显式 close，确认无 `-wal` / `-shm`；
8. 到此才进入正式 replacement。

包含 unknown future migration 的 snapshot 必须在替换前拒绝；不得降级、删除 migration 行或猜测读取。migration/quick-check 失败只删除本次工作副本，不改变正式库。

当前生产只有 v001。旧 schema 正例可用真实 SQLite 空库（applied migration prefix 为空）证明工作副本能够升级到 v001；不得为了测试增加生产 v002 或修改 v001。

## 9. 正式替换、验证与补偿

### 9.1 第一次安全替换

替换操作使用：

- original item：正式 `ImageAll.sqlite`；
- new item：同卷、已关闭、无 sidecar 的工作副本数据库；
- backup item name：唯一、只含文件名的 `ImageAll.sqlite.pre-restore-<operation-id>`；
- options：包含 `.withoutDeletingBackupItem`。

调用者必须使用 Foundation 返回的 resulting URL 语义，不能假设 replacement 后 inode/URL 身份必然不变。替换失败时保留 Foundation 报告的 original-item location 诊断，但对上层暴露结构化错误；不能随后删除任一不确定归属的数据库文件。

### 9.2 替换后验证

第一次替换成功后：

1. 从正式路径重新打开数据库；
2. 拒绝 future schema，验证当前完整 migrations、foreign keys 与 `PRAGMA quick_check`；
3. 显式 close；
4. 确认正式路径没有遗留候选 `-wal` / `-shm`；
5. 返回成功结果，其中包含 retained pre-restore backup item URL。

本切片验证后保持数据库关闭；切片 6 再负责正式打开、恢复 Jobs 与发布 readiness。

### 9.3 post-replace 失败自动回滚

若重新打开、migration history 或 quick check 在第一次替换后失败：

1. 关闭 post-replace 验证连接；
2. 处理失败候选创建的 sidecar，确保不会污染原库回滚；
3. 再次调用同卷 `replaceItem`：以当前正式路径的失败候选为 original，以 retained pre-restore backup item 为 new；
4. 第二次替换提供唯一 `ImageAll.sqlite.quarantine-<operation-id>` backup item name，并保留该 backup item；
5. 回滚成功后，正式路径恢复为替换前数据库，失败候选保留为 quarantine；
6. 重新打开原活动库做 best-effort quick check 并关闭；无论原库本来是否健康，都返回“恢复未完成、已回滚”的结构化结果；
7. 测试必须证明正式库事实/bytes 恢复、quarantine 存在、无候选 WAL/SHM 混入。

禁止通过“删掉失败候选再 move backup”回滚。若第二次 replace 本身失败，停止所有清理，保留 Foundation 返回的位置与所有已知 artifact，返回需要人工介入的结构化错误；不得创建空库或继续尝试无界补偿。

## 10. 错误与失败注入契约

错误至少能区分以下类别；具体 Swift case 命名可按现有风格调整：

- invalid/unsupported manifest；
- snapshot ID、database filename、size、checksum 不匹配；
- invalid、mismatched 或 future migration history；
- snapshot/candidate integrity check failure；
- snapshot collision、temporary write、publication rename failure；
- checkpoint/close/sidecar convergence failure；
- candidate preparation/migration failure；
- initial replacement failure；
- post-replace validation failure with successful rollback；
- rollback replacement failure requiring manual intervention。

错误不得包含 bookmark BLOB、完整图片路径、Photos identifier、payload 或原始 SQL。不要把底层任意 `localizedDescription` 直接持久化或展示。

为证明失败安全，测试 seam 至少能确定性注入：

1. online backup 在未完成 step 中止；
2. manifest write 或 final publish rename 失败；
3. initial replacement 失败；
4. 第一次 replacement 后的 reopen/quick check 失败；
5. rollback replacement 失败。

正路径必须使用真实 GRDB backup 与真实 `FileManager.replaceItem`；不能因为需要 fault injection 而把整个 snapshot/restore 流程改成 mock。

## 11. TDD 测试矩阵

每簇先出现能失败的测试，再写最少实现。Cursor 回传需列出红灯原因和绿灯证据。

### 11.1 Manifest 与 discovery

正例：

- v1 encode/decode 往返，字段语义完整；
- 合格 final UUID 目录被列出，按 `created_at_ms DESC, snapshot_id ASC` 稳定排序；
- SHA-256 是关闭后数据库的 64 位小写十六进制；
- 未知额外 JSON 字段不破坏 v1 解码。

反例：

- malformed JSON、unsupported `format_version`；
- 非规范 UUID、目录与 manifest ID 不同；
- 非固定 database filename、symlink database/manifest；
- bytes 不同、hash 不同或 uppercase hash；
- migration 重复、未知、乱序/非前缀；
- `.tmp`、缺 manifest、存在 `-wal`/`-shm` 的目录不列出。

### 11.2 Snapshot 创建

正例：

- 手动入口创建 final 目录，数据库 quick check 为 ok，事实与 migrations 一致；
- migration 前入口复用同一 primitive；
- backup 期间并发事务后产物一致，符合第 7 节；
- 创建成功后 temp 不存在，已有 snapshot 不变。

反例：

- ID/temp/final 碰撞不覆盖已有内容；
- backup step 中止、quick check、close、manifest write、hash 或 rename 失败均不发布 final；
- 每项失败只清理本次 temp，live DB 事实逐列不变；
- manifest migration list 来自 snapshot DB，测试能发现 source/snapshot 跨时点拼接的错误实现。

### 11.3 Snapshot 恢复前校验与 migration

正例：

- same-schema snapshot 恢复后 source/asset/tag/decision/job 代表事实完全一致；
- 空 migration prefix 的旧 schema snapshot 只在工作副本升级到 v001；
- 工作副本 migration/quick check 后无 WAL/SHM，正式库在 replacement 前不变。

反例：

- 坏 JSON、坏 hash、坏 size、坏 quick check、manifest/database migration mismatch 全部在 replacement 前拒绝；
- unknown future migration 拒绝，正式库不变；
- 工作副本 migration/quick check 失败只清理工作副本；
- active checkpoint/close 失败不调用 replacement；
- 候选与正式库不同 volume 或 replacement precondition 不满足时拒绝。

### 11.4 Replacement 与回滚

正例：

- 真实同卷 `replaceItem` 成功，恢复事实匹配 snapshot；
- retained pre-restore backup item 存在，包含替换前事实；
- post-replace reopen/quick check 成功，正式库和候选无 WAL/SHM。

反例：

- initial replacement 注入失败：正式库 bytes/事实不变，无 delete-first 窗口；
- post-replace validation 注入失败：第二次真实 replacement 自动回滚，正式库恢复，失败候选进入 quarantine；
- 回滚后原库与 quarantine 不共享候选 sidecar；
- rollback replacement 注入失败：不继续删除/移动，返回 manual-intervention 类错误并保留所有可定位 artifact。

### 11.5 范围与回归

- 全部测试只使用每例独立临时目录、真实文件数据库和合成事实；
- 测试/生产源码不得包含 `/Volumes/HDD2` 或受保护路径；
- 原 177 项全部通过；
- Domain/Application 不新增 GRDB 依赖，Infrastructure 不导入 SwiftUI；
- `v001_create_catalog_core`、Job 语义、UI、target/scheme/entitlement/Package.resolved 不变；
- 不出现 AppPaths、process lock、正式容器、startup readiness 或真实来源代码。

## 12. 验收门与回传证据

### 12.1 自动化门

- `xcodebuild test -scheme ImageAll -destination 'platform=macOS'` 退出 0；
- 从新的 `.xcresult` 报告实际总数、失败数、跳过数，不能只贴日志中的 `TEST SUCCEEDED`；
- `xcodebuild build -scheme ImageAll -destination 'platform=macOS' -configuration Debug` 退出 0；
- `git diff --check` 无输出；
- 用实际产物证明 snapshot manifest、目录形状、quick check、migration list、hash/size 与 sidecar 状态；
- 用真实同卷临时目录证明 replacement/retained backup item/rollback/quarantine；
- Swift 6、GRDB 7.11.1 与已批准工程边界无回退；
- 无 `/Volumes/HDD2` 访问、硬编码、测试日志或产物。

### 12.2 Git 门

- 从包含本交接单、由 Codex 调用明确给出的精确 `main` HEAD 开工；
- 只提交切片 5 的 Infrastructure snapshot/restore、测试和必要 Xcode 文件引用；
- 不修改已批准 v001、Domain/Job/UI 语义和无关文档；
- 创建窄范围本地 commit；返修只追加 commit，不 amend 已审计历史；
- 不 push；交付后工作区干净。

### 12.3 Cursor 必须回传

遵守 `.cursor/rules/codex-review-handoff.mdc`，并至少提供：

1. `system/init.model`、全新 Cursor session ID、开工与交付 commit；
2. 每个新增/修改文件的单一职责；
3. GRDB 7.11.1 online backup API 的实际调用边界；
4. manifest v1 示例与逐字段校验证据，确认无 bookmark/plain path；
5. 并发 backup 测试怎样证明写入发生在 step 之间，以及为何允许事务全有/全无；
6. 创建每个失败点的 temp/final/live DB 结果；
7. same-schema、旧 known-prefix、future/mismatch 三类恢复证据；
8. checkpoint、close、WAL/SHM 清理发生的精确顺序；
9. 第一次 replace 的 resulting URL、retained backup item 和 no-delete-first 证据；
10. post-replace validation 失败后的第二次 replace、回滚、quarantine 和 artifact 结果；
11. 完整 test/build/xcresult/diff-check 结果；
12. v001/Job/UI/依赖/工程/HDD2 未变化声明；
13. 明确停止于切片 5，未进入切片 6。

## 13. Codex 复审重点

Codex 将独立核对：

- 是否真正使用 SQLite online backup，而非复制 live 主文件；
- manifest migrations 是否从目标快照读取，hash 是否在关闭后计算；
- temp 失败是否绝不发布，snapshot discovery 是否排除不完整/坏项；
- 并发测试是否真的把 write 安排在 backup steps 之间；
- snapshot 原目录是否保持不可变，migration 是否只发生在工作副本；
- future/mismatch schema 是否在 replacement 前拒绝；
- checkpoint、close 与 WAL/SHM 处理是否满足独占前提；
- 是否使用 Foundation 同卷带 backup item replacement，是否存在 delete-first 窗口；
- post-replace 失败是否自动恢复原活动库并隔离候选；
- 故障注入 seam 是否足够窄，正路径是否仍使用真实 GRDB/FileManager；
- 是否提前进入 AppPaths、进程锁、启动集成或真实数据范围。

只有切片 5 通过复审，才授权进入切片 6。阶段 0 此时仍未完成。

## 14. 资料依据

- [SQLite: Backup API](https://www.sqlite.org/backup.html)
- [SQLite: Online Backup C API](https://www.sqlite.org/c3ref/backup_finish.html)
- [SQLite: Write-Ahead Logging](https://www.sqlite.org/wal.html)
- [SQLite: PRAGMA wal_checkpoint](https://www.sqlite.org/pragma.html#pragma_wal_checkpoint)
- [Apple: FileManager.replaceItem](https://developer.apple.com/documentation/foundation/filemanager/replaceitem(at:withitemat:backupitemname:options:resultingitemurl:))
- [GRDB 7.11.1: Backup](https://github.com/groue/GRDB.swift/blob/v7.11.1/README.md#backup)
