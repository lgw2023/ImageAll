# ImageAll 阶段 0 验收证据

> 状态：Completed<br>
> 验收日期：2026-07-15<br>
> 批准实现：`main@892f4e29e1ebf492c1540c5a29d9c54abc05a78f`<br>
> 规格：[STAGE-0-IMPLEMENTATION-SPEC.md](./STAGE-0-IMPLEMENTATION-SPEC.md)

## 1. 验收结论

Gate 0 与切片 1–6 已完成并通过 Codex 独立复审。阶段 0 建立的边界为：SwiftUI 应用空壳、纯领域规则、GRDB v001 目录库、持久化 Job 状态机、目录库快照与安全恢复、AppPaths、进程独占锁，以及只有在正式目录库打开和中断 Job 恢复成功后才发布的 `CatalogReady` gate。

本结论不表示文件夹导入、PhotoKit、扫描、缩略图、OCR、embedding、模型或标签产品界面已经实现；这些仍属于阶段 1 及以后。

## 2. 工具链与工程基线

| 项目 | 验收值 |
|---|---|
| 系统 | macOS 26.5.1（25F80），arm64 |
| Xcode | 26.6（17F113） |
| Swift | 6.3.3；工程语言模式 Swift 6 |
| SDK | macOS 26.5 |
| Deployment Target | macOS 15.0 |
| Bundle Identifier | `com.gwlee.ImageAll` |
| 依赖 | GRDB 7.11.1，revision `b83108d10f42680d78f23fe4d4d80fc88dab3212` |
| Target / Scheme | `ImageAll`、`ImageAllTests`；共享 scheme `ImageAll` |
| Entitlement | 源声明仅 App Sandbox；Debug 产物另含工具链注入的 `get-task-allow` |

## 3. 切片与提交

| 门 | 最终批准实现 | 结果 |
|---|---|---|
| Gate 0 / 切片 1 | `01fbed6` | SwiftUI 空壳、Composition Root、Swift 6 语言模式 |
| 切片 2 | `80ef5cf` | 领域封闭词汇、标签名称、人工决定与 Source/Asset 规则 |
| 切片 3 | `b0d02ab` | GRDB v001、六张 STRICT 业务表、七个命名索引、最小 Repository |
| 切片 4 | `e207180` | 持久化 Job 状态机、claim、控制请求、checkpoint 与崩溃恢复语义 |
| 切片 5 | `562f778` | 一致性快照、manifest、工作副本恢复、原子替换与回滚 |
| 切片 6 | `892f4e2` | AppPaths、`flock`、安全 bootstrap、readiness gate 与启动 UI |

切片 6 由 Cursor CLI session `2f994f17-ec69-4b2d-a9cc-c8652ace0713` 使用 `Composer 2.5 Fast` 实施；完整命令、任务正文、三轮返修和提交归属见 [Cursor CLI 任务记录](./cursor-cli-tasks/2026-07-14-stage-0-slice-6.md)。该 session 在本验收后退役。

## 4. 自动化验收

Codex 在批准实现 `892f4e2` 上独立执行：

```bash
xcodebuild -scheme ImageAll -destination 'platform=macOS' \
  -configuration Debug \
  -resultBundlePath /tmp/ImageAll-Codex-Final-1784045357.xcresult test

xcrun xcresulttool get test-results summary \
  --path /tmp/ImageAll-Codex-Final-1784045357.xcresult

xcodebuild -scheme ImageAll -destination 'platform=macOS' \
  -configuration Debug build

git diff --check
git status --short --branch
```

结果：

- `.xcresult`：`totalTestCount = 268`、`passedTests = 268`、`failedTests = 0`、`skippedTests = 0`、`result = Passed`；
- Debug build：`BUILD SUCCEEDED`；
- `git diff --check`：无输出；
- 验收前实现工作区：干净的本地 `main`；
- GRDB 解析版本仍为 7.11.1；v001、依赖锁、target、scheme 与 entitlement 未被切片 6 改写。

覆盖包括领域规则、真实文件数据库约束、事务回滚、Job 并发 claim/恢复、快照一致性、坏 manifest、WAL checkpoint、工作副本 migration、替换失败/自动回滚、进程锁、启动顺序、非主线程 I/O、legacy sentinel 保留，以及 checkpoint/close/convergence 失败时零 replacement、零 final open。

## 5. Schema dump 证据

验收 App 容器中的正式目录库以只读 `sqlite3` 查询 `sqlite_schema`；自动化测试同时在 GRDB 连接上验证 `journal_mode=wal`、`foreign_keys=1` 与 `quick_check=ok`。

```text
applied_migrations=v001_create_catalog_core
schema_sha256=194674d8a836d8be71ae146fac3ed060601ed28e0ad2f5a4a756507c9323a2dd
journal_mode=wal
quick_check=ok
foreign_keys_on_app_connection=1

tables=
asset,asset_tag_decision,file_fingerprint,grdb_migrations,job,source,tag

strict=
asset:1,asset_tag_decision:1,file_fingerprint:1,job:1,source:1,tag:1

named_indexes=
asset_current_file_locator_uq
asset_current_photos_locator_uq
asset_source_availability_idx
decision_tag_idx
job_active_coalescing_uq
job_queue_idx
tag_normalized_name_uq
```

`schema_sha256` 是对只读正式库执行 `sqlite3 '.schema'` 原始输出所得的 SHA-256。完整原始 DDL 的规范来源为 [V001CreateCatalogCoreMigration.swift](../ImageAll/Infrastructure/Database/V001CreateCatalogCoreMigration.swift)，真实 metadata、列、FK、索引键、partial predicate、STRICT 与原始 `sqlite_schema.sql` 由 [CatalogSchemaTests.swift](../ImageAllTests/Database/CatalogSchemaTests.swift) 固定。

## 6. 非破坏启动 smoke

在最终 Debug 产物上执行双实例 smoke；未删除或重置已有 App container 数据。

第一实例的结构化安全日志：

```text
catalogState=starting stage=paths
catalogState=starting stage=lock
catalogState=starting stage=catalog
catalogState=starting stage=recovery
catalogState=catalogReady
```

第二实例在第一实例仍存活时启动：

```text
catalogState=starting stage=paths
catalogState=starting stage=lock
catalogState=anotherInstanceRunning
```

观察到两个不同 PID；第二实例未进入 catalog/recovery，第一实例仍存活。沙盒应用支持目录只包含阶段 0 需要的布局：

```text
ImageAll/
├── Catalog/ImageAll.sqlite（运行时允许 WAL/SHM）
├── Backups/
└── Runtime/catalog.lock
```

两个进程随后使用 `TERM` 正常结束。smoke 与自动化均未读取、列举或修改 `/Volumes/HDD2` 受保护真实照片来源。

## 7. 已知限制与后续门

- Intel 未验证，`ARCHS` 未写死；最低 macOS 版本和 Intel 支持须在阶段 1 开工前冻结；
- 当前为本地 ad-hoc Debug 签名，Developer ID / Mac App Store 尚未决定；
- 当前 UI 只显示 `foundationReady` 与目录库状态 token，不是产品界面；
- 阶段 0 没有 scheduler loop 或真实扫描 handler；
- 本次以结构化日志证明 `CatalogReady` 和双实例行为，没有把 UI 自动化或截图设为完成前提；
- 真实照片仍只允许在后续明确授权的只读人工验证中使用，规则见 [LOCAL-TEST-DATA-SAFETY.md](./LOCAL-TEST-DATA-SAFETY.md)。
