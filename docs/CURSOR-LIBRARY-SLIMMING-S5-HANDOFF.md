# Cursor 交接单：图库瘦身 S5（Photos PhotoKit 回收 + 对账）

> 状态：Closed（原 S5 交付后，经 2026-07-27 所有者确认与 Codex 复审完成契约修正）
> 日期：2026-07-27  
> 权威规格：[`LIBRARY-SLIMMING-SPEC.md`](LIBRARY-SLIMMING-SPEC.md) §5.2 / §5.3 / §7 S5；[`ADR-042-LIBRARY-SLIMMING-AND-RECYCLE.md`](ADR-042-LIBRARY-SLIMMING-AND-RECYCLE.md)  
> 上一批准基线：`main@3e44f622e203bc6e3a1da0b71925575384e09fc9`（含 S4 交付与 recycle 安全硬化）  
> 角色：临时授权期内可由本会话直接实施；交付 commit 使用实施身份与 `Agent-Role: implementation`

> 复审纠偏：本交接单早期版本错误地假设可用未公开 subtype 枚举系统「最近删除」并再次调用删除实现永久删除。该契约已被撤销；权威语义以 ADR-042 与 `LIBRARY-SLIMMING-SPEC.md` 当前版本为准。修正实现 commits：`f181fed1`、`11ad55e7`。

## 1. 范围

交付 **Apple Photos** 轨道的可恢复回收站，并与文件夹轨道统一呈现在回收站 UI（全能力最小闭环）：

1. **Migration v021**：`recycle_entry` 增加 `photos_local_identifier`（Photos 条目非空；文件夹条目必须为 NULL）；CHECK 与 `source_kind` 互斥；`RecycleEntryRecord` 暴露该字段；
2. **`PhotosLibraryMutationPort`**（新应用契约）+ PhotoKit 适配器（**唯一**允许引用 `PHAssetChangeRequest` / `performChanges` / `deleteAssets` 的生产模块）：
   - `authorizationState` / 必要时 `requestAuthorization`（沿用 `.readWrite`）；
   - `moveToRecentlyDeleted(localIdentifiers:)` → 系统「最近删除」；
   - `presence(localIdentifier:)` → 生产适配器只返回公开 PhotoKit 可证明的 `available` / `missing`；`recentlyDeleted` 仅保留给确定性测试或非 PhotoKit 适配器；
   - 不提供 ImageAll 发起的 Photos 永久删除能力，不访问未公开的「最近删除」相册 subtype；
3. **回收服务扩展**：`moveFolderAssetsToRecycle` 升级为（或并列）统一 `moveAssetsToRecycle`：文件夹仍走 quarantine；Photos 走 PhotoKit，写 `recycle_entry(source_kind=photos, photos_local_identifier=…)`，`availability=recycled`，**禁止**把 Photos 像素写入 App quarantine；
4. **恢复**：
   - 文件夹：保持 S4 行为；
   - Photos：公开 PhotoKit **无** undelete API。契约冻结为：
     - 若 `presence == .available`（用户已在系统 Photos 恢复）→ 本地标记 `restored` + `availability=available`；
     - 若为 `recentlyDeleted` / `missing` → 抛可观察错误（如 `photosRestoreRequiresPhotosApp`），条目保持回收站；UI 文案引导在 Photos「最近删除」中恢复；
5. **本地记录清理**：Photos 不提供 ImageAll「立即永久删除」；系统恢复与永久删除由 macOS「照片」App 管理。到 `purge_after_ms` 后，ImageAll 只收敛自己的回收记录与 catalog，不声明或触发系统永久删除；
6. **对账**：提供 `reconcilePhotosRecycleEntries()`（可在打开回收站 Tab / recoverInterrupted / purge 前调用）：以公开 PhotoKit 可见性为依据——`available`→restored；`missing` 在本地清理时间前继续保留记录，到期后仅收敛本地状态；
7. **授权门**：Photos 未授权 / 非 authorized → 拒绝并说明；**不得**静默跳过伪装成功；文件夹 mutation bookmark 逻辑不变；
8. **UI**：去掉「已跳过 Photos（S5）」；成功移入含 Photos 时显示数量；回收站来源徽章「Photos」；Photos 显示恢复引导与本地记录清理时间，不显示 ImageAll 永久删除按钮；
9. **静态审计更新**：原「全仓零 mutation API」改为「仅瘦身 Photos mutation 适配器可出现；其它模块仍为零」；测试用 Fake mutation port，**禁止**对 `/Volumes/HDD2` 或真实 `.photoslibrary` 做删除测试；
10. **测试**：授权拒绝、软删写 DB、无 quarantine 副作用、pending/purging 崩溃恢复、presence 对账 restored/本地收敛、拒绝 Photos purge、文件夹回归仍绿、mutation API 仅出现在允许文件。

## 2. 明确不做

- 把 Photos 像素导出到 App quarantine / 直写 `.photoslibrary`
- 使用私有 / 未文档化 undelete API
- 自动清空相似簇、无确认批删
- 对受保护真实路径做任何删除/移动测试
- 阈值 UI、性能分桶、簇结果持久化（S6 / 延后）
- 改写已批准 migration V001–V020

## 3. 契约要点

| 项 | 值 |
|---|---|
| 迁移 | `v021_add_photos_recycle_identifier` |
| `recycle_entry.photos_local_identifier` | `source_kind=photos` 时非空；`file` 时必须 NULL；与 quarantine 互斥（photos 不得有 quarantine_relative_path） |
| Mutation 唯一落点 | `Infrastructure/Photos/*Mutation*`（或等价单文件）；其它生产 Swift 不得出现 `PHAssetChangeRequest` / `deleteAssets` / `performChanges` |
| 软删 | PhotoKit `deleteAssets` → 最近删除；DB `recycled` |
| 恢复 | 无公开 undelete；依赖用户在 Photos 恢复 + presence 对账，或显式失败引导 |
| 永久删 | ImageAll 不提供；由 macOS「照片」App 管理 |
| 主库 | 继续默认隐藏 `recycled` |
| Outcome | 不再把 Photos 计入 `skippedPhotosAssetIDs` 成功路径；该字段可保留兼容但应为空，或改为 `authorizationDeniedPhotosAssetIDs`（若改名需同步 UI/测试） |

## 4. 测试矩阵

1. Photos 未授权 → move 失败/拒绝，无 DB recycle 成功行，无 PhotoKit 副作用（Fake）
2. Photos 软删：Fake mutation 记录 localIdentifier；DB `source_kind=photos` + `photos_local_identifier`；quarantine 目录无新文件；asset `recycled`
3. 对账：presence=`available` → entry `restored`，asset `available`
4. 对账/到期：presence=`missing` 在本地清理时间前保留，期限到后仅收敛 ImageAll 记录
5. Photos 立即 purge 被拒绝，适配器无永久删除方法或调用
6. 恢复按钮在 presence=`recentlyDeleted` 时返回可观察错误，条目仍在回收站
7. 文件夹同卷/恢复/purge 回归仍绿
8. `rg` 审计：mutation 符号仅出现在允许的适配器 + 测试 Fake（可选单测断言文件白名单）
9. 生产代码无未公开「最近删除」 subtype，源 snapshot / 受保护路径零触及

## 5. 停止位置

S5 绿灯并本地提交后停止；**不进入 S6**（性能分桶 / 阈值可配置）。MVP「图库瘦身」验收门在 S5 交付且 Codex 复审通过后关闭。
