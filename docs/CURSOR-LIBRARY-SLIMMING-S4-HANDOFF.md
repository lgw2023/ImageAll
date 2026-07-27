# Cursor 交接单：图库瘦身 S4（文件夹 quarantine 回收站）

> 状态：Ready  
> 日期：2026-07-27  
> 权威规格：[`LIBRARY-SLIMMING-SPEC.md`](LIBRARY-SLIMMING-SPEC.md) §5.1 / §5.3 / §6 / §7 S4；[`ADR-044-LIBRARY-SLIMMING-AND-RECYCLE.md`](ADR-044-LIBRARY-SLIMMING-AND-RECYCLE.md)
> 上一批准基线：`main@95cd8cd898e03517d030588c627cbda79f265640`（含 S3 交付与复审加固）  
> 角色：临时授权期内可由本会话直接实施；交付 commit 使用实施身份与 `Agent-Role: implementation`

## 1. 范围

交付**文件夹**资产的可恢复回收站（仍不含 Photos 写入）：

1. **Migration v019**：`recycle_entry` 表；`asset.availability` CHECK 扩展含 `recycled`；`AssetAvailability.recycled`；可选 `source.mutation_bookmark`（可写授权，与只读 bookmark 分离）；
2. **Quarantine 根**：位于 App Application Support（如 `…/ImageAll/Quarantine/`），按 `source_id/asset_id` 分片；不得写回用户相册旁隐藏目录；
3. **移入回收站**：用户确认后，事务意图先写 `recycle_entry(state=pending)` → 同卷 `renameat`（FD / no-follow）或跨卷 copy→校验→删源（失败不得删源）→ 成功后 `state=recycled`、`availability=recycled`、记录 `quarantine_relative_path`、`trashed_at_ms`、`purge_after_ms=trashed_at+30d`；主图库默认隐藏；
4. **恢复**：quarantine 逆移回原 `relative_path`；目标已存在则失败并保持回收站；成功后 `state=restored`、`availability=available`；
5. **到期 / 立即永久删除**：删除 quarantine 对象；`state=purged`；级联清理可重建派生物与该资产索引行（或等价硬删除 asset）；提供可恢复 **purge Job**（扫描到期条目）；
6. **写入授权**：沙盒下来源只读 bookmark **不能** rename/unlink；S4 必须经独立 mutation 授权（`mutation_bookmark` 无 `.securityScopeAllowOnlyReadAccess`）。缺授权时拒绝并提示重新选择文件夹；测试用注入式可写 root，不弹面板；
7. **UI**：瘦身工作台内 Tab 或同区入口「回收站」；列表显示缩略图/文件名、倒计时（≥24h 显示天，否则小时）、恢复、立即删除；簇内多选后「移入回收站」需确认文案（含数量）；Photos 成员选中时跳过并说明「S5」；
8. **测试**：同卷 rename、跨卷 copy+校验、恢复冲突、到期 purge、失败不丢源、主库隐藏 recycled、源 snapshot/受保护路径零触及；仅合成 fixture。

## 2. 明确不做

- PhotoKit mutation / Photos 进系统「最近删除」/ Photos 对账（S5）
- 把 Photos 像素导出到 App quarantine
- 自动清空相似簇、无确认批删
- 对 `/Volumes/HDD2` 受保护真实数据做任何删除/移动测试
- 阈值 UI、性能分桶、簇结果持久化（S6 / 延后）
- 改写已批准 migration V001–V018

## 3. 契约要点

| 项 | 值 |
|---|---|
| 迁移 | `v019_add_library_slimming_recycle` |
| `recycle_entry` | id, asset_id, source_kind=`file`（S4 仅 file）, trashed_at_ms, purge_after_ms, state(`pending`/`recycled`/`restored`/`purged`/`failed`), quarantine_relative_path?, original_relative_path, error_code? |
| 倒计时 | `purge_after_ms - now`；UI 按条目独立 |
| 同卷 | 设备号相同 → exclusive rename 进 quarantine |
| 跨卷 | copy 到 quarantine → 字节/尺寸校验 → 再 unlink 源；校验失败保留源与 pending/failed |
| 主库 | 默认 `AssetPageFilter` / 浏览不含 `recycled` |
| Job | `librarySlimming.purgeExpired.v1`（或等价）；可 enqueue + handler 执行到期 purge |
| Photos | 选中含 photos locator 时不得调用文件夹 quarantine；返回可观察跳过原因 |
| 安全 | 复用 `DerivedImageSecureIO` / `RelativePathRules`；quarantine 路径校验；只读 bookmark 路径零写入 |

## 4. 测试矩阵

1. 同卷：fixture 文件从 source 消失、出现在 quarantine；DB `recycled`；主库 list 不可见
2. 跨卷（两临时卷根或不同 device 模拟）：copy+校验成功后源删除；失败路径源仍在
3. 恢复：回到原 relative_path；若预先放置冲突文件 → 恢复失败且仍在回收站
4. 立即 purge 与到期 purge Job：quarantine 文件删除；state=`purged`
5. pending 阶段 IO 失败 → state=`failed` 或回滚，源文件仍在
6. Photos 资产请求回收 → 拒绝/跳过，无文件系统副作用
7. 倒计时文案边界：≥24h 显示天；&lt;24h 显示小时（纯函数单测即可）
8. 回归：既有 Similarity / LibraryWorkspace 关键测试仍绿

## 5. 停止位置

S4 绿灯并本地提交后停止；**不进入 S5**（PhotoKit 回收/恢复/永久删与统一 Photos 对账）。
