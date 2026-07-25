# Release Notes — 性能优化批次（存储迁移 / 空闲预热 / 视频排除）

**版本标签：** `v2026.07.25-perf-opt`  
**合入分支：** `main`  
**Commit 范围：** `f00cf256..3d14987e`（8 commits）  
**发布日期：** 2026-07-25  
**权威交接单：** [`docs/PERF-OPT-STORAGE-IDLE-VIDEO-HANDOFF.md`](../PERF-OPT-STORAGE-IDLE-VIDEO-HANDOFF.md)

---

## 摘要

本批次完成性能优化交接单的三个切片（A/B/C），并附带两项缩略图体验修复与一项启动迁移竞态修复：

- **切片 A**：视频/非图片永不入库，并清除已入库视频资产
- **切片 B**：空闲 3 分钟（默认开启）自动预热当前网格缩略图
- **切片 C**：整包应用存储外置迁移的可观察任务与进度 UI，支持安全取消
- **附加**：侧边栏手动预热、网格缩略图从 SSD 缓存派生（避免重复读 HDD）、启动重试/取消时丢弃过期 bootstrap 结果

---

## 新功能

### 整包存储迁移任务与进度（切片 C）

- 启动路径解析期间报告单调递增的迁移进度（阶段、字节/文件计数）
- 迁移完成标记写入前支持安全取消
- 设置页展示待迁移 / 进行中 / 完成态
- 新增 `storageMigrationCancelled` 不可用原因；取消后进度 phase 归一为 `.cancelled`

### 空闲缩略图预热（切片 B）

- 新设置项「空闲时预生成缩略图」，**默认开启**
- 无用户交互满 **180 秒** 后，以低于浏览优先级预热当前网格缩略图
- 任意指针/键盘/滚动交互立即取消预热，优先保证视口加载

### 手动源缩略图预热

- 资料库来源侧栏右键菜单：预生成该来源网格缩略图至派生磁盘缓存
- 工具栏显示进度，支持取消

### 视频/非图片排除（切片 A）

- 文件夹枚举跳过明显非图片文件（含视频扩展名/UTI）
- 启动时清除已入库视频类 `asset` 及其 `asset_tag_decision`
- Photos 适配器保持仅静态图片

---

## 修复

### 网格缩略图占位符卡死（HDD 重复读取）

- **问题**：preview 已在 SSD 缓存但 `gridRegular` 未命中时，网格仍显示占位符，因加载路径重新打开 HDD 原图且受极小并发门控限制
- **修复**：从已缓存 preview（或 `gridRegular` 用于 `gridSmall`）派生网格变体并持久化，后续直接命中

### 启动 bootstrap 竞态与迁移取消

- **问题**：重试或取消迁移时，旧 generation 的 bootstrap 结果可能覆盖新状态
- **修复**：引入 `bootstrapGeneration` 与独立 `MigrationCancelFlag`；过期 ready token 自动 close；不可用态下规范化迁移进度 phase

---

## 架构与契约

| 变更 | 说明 |
|------|------|
| `AppPathsResolving.resolvingWithMigrationHooks` | 迁移进度/取消 hook 的可测试抽象 |
| `CatalogUnavailableReason.storageMigrationCancelled` | 用户取消外置存储迁移的显式 outcome |
| `insufficientSpace(requiredBytes:)` | display token 携带所需字节数 |

---

## 测试

| 套件 | 覆盖 |
|------|------|
| `CatalogStartupPresentationTests` | 迁移取消、重试丢弃过期结果、失败后恢复、不足空间 token |
| `CatalogStartupConcurrencyTests` | 容量检查不阻塞主线程 |
| 切片 A/B 相关测试 | 视频排除、空闲预热、手动预热（见各 commit） |
| `DerivedImageCacheHitAndConcurrencyTests` | 网格从 preview 派生、并发命中 |

本地验收（2026-07-25）：

```bash
xcodebuild test -scheme ImageAll -destination 'platform=macOS' \
  -only-testing:ImageAllTests/CatalogStartupPresentationTests \
  -only-testing:ImageAllTests/CatalogStartupConcurrencyTests
# TEST SUCCEEDED
```

---

## Commit 清单

| Hash | 类型 | 说明 |
|------|------|------|
| `b1699151` | docs | handoff：存储迁移 / 空闲预热 / 视频排除 |
| `942b2003` | feat | 排除并清除非图片视频资产 |
| `6dcf86b8` | feat | 空闲 3 分钟缩略图预热（默认开） |
| `64c2c521` | feat | 整包存储迁移任务与进度 UI |
| `27943936` | docs | 关闭 perf-opt handoff（A/B/C 完成） |
| `876b3921` | feat | 侧栏手动源缩略图预热 |
| `86734f26` | fix | 网格缩略图从 SSD 缓存 preview 派生 |
| `3d14987e` | fix | 迁移取消与 superseded bootstrap 丢弃 |

---

## 已知限制

- 外置存储迁移仍需在目录库未打开时执行；活跃 SQLite 不会原地搬移
- 空闲预热仅覆盖当前来源/查询可见网格，非全库强制预热
- 未访问 `/Volumes/HDD2` 或真实 Photos 库；生产烟测需所有者单独授权

---

## PR 描述（归档）

> 以下为合入 `main` 时等效的 Pull Request 描述，供 Code Review 与发布归档使用。

### Title

`feat: perf-opt batch — storage migration progress, idle prewarm, video exclusion`

### Summary

- **Slice A**: Skip non-image/video files during folder enumeration; purge already-ingested video assets and tag decisions on startup.
- **Slice B**: Default-on idle thumbnail prewarm after 180s of inactivity; any user interaction cancels background work.
- **Slice C**: Whole-package external storage migration with monotonic progress UI and safe cancel before completion marker.
- **Follow-ups**: Manual source prewarm from sidebar; derive grid thumbnails from cached preview to avoid HDD reread; bootstrap generation guard for retry/cancel races.

### Test plan

- [x] `CatalogStartupPresentationTests` — migration cancel, superseded bootstrap discard, failure recovery
- [x] `CatalogStartupConcurrencyTests` — capacity check off main thread
- [x] Video exclusion and purge tests (slice A)
- [x] Idle prewarm interrupt tests (slice B)
- [x] Derived image grid-from-preview tests
- [x] Debug build on macOS

### Breaking changes

None.

### Docs

- Handoff: `docs/PERF-OPT-STORAGE-IDLE-VIDEO-HANDOFF.md` (closed)
- Task log: `docs/cursor-cli-tasks/2026-07-25-perf-opt-storage-idle-video.md`
