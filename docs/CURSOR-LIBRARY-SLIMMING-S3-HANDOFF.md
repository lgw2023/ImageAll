# Cursor 交接单：图库瘦身 S3（种子/标签入口 + 簇内多选对比）

> 状态：Ready  
> 日期：2026-07-27  
> 权威规格：[`LIBRARY-SLIMMING-SPEC.md`](LIBRARY-SLIMMING-SPEC.md) §3.3 / §7 S3；[`ADR-044-LIBRARY-SLIMMING-AND-RECYCLE.md`](ADR-044-LIBRARY-SLIMMING-AND-RECYCLE.md)
> 上一批准基线：`main@d205f555c730103f206472856d3fe27d0c15099f`（含 S2 交付与复审加固）  
> 角色：临时授权期内可由本会话直接实施；交付 commit 使用实施身份与 `Agent-Role: implementation`

## 1. 范围

交付只读查询入口与簇内对比 UX（仍不删原图）：

1. **标签/当前筛选范围入口**：瘦身工作台可「分析当前筛选范围」，以主图库当前 `AssetPageFilter`（含标签决策过滤）解析出的资产宇宙做闭包聚类（复用 `scan(assetIDs:)`）；
2. **种子图入口**：图库主网格在有多选时可「在图库瘦身中查找」；以选中资产为 query，在全库（或用户已收窄的筛选宇宙）检索相同/相似，命中项与种子并成簇；
3. 工作台内可切换分析模式：当前库 / 当前筛选 / 当前种子（若有）；
4. **簇内多选对比**：簇成员网格支持点选 / ⌘ 多选；至少两张选中时可并排大图对比（复用既有 preview 加载）；仍只读；
5. 单元测试证明：标签范围只扫描匹配 ID；种子检索能召回库内近邻且不把「仅种子互比」冒充全库结果；簇成员选择状态可测试。

## 2. 明确不做

- 移入回收站 / quarantine / PhotoKit mutation（S4+）
- 簇结果持久化 migration（可继续内存 run）
- 全库可恢复 Job、阈值设置 UI、性能分桶（S6）
- 人脸身份、以图搜视频

## 3. 契约要点

| 项 | 值 |
|---|---|
| 范围扫描 | `scan(assetIDs:)` 闭包；资产宇宙 = 当前筛选解析出的全部可用 ID（需分页或专用 ID 列表，不得只取已加载的一页） |
| 种子扫描 | 新端口方法（建议 `scanSeeds(seedAssetIDs:universeAssetIDs:onProgress:)`）：对每个种子在 universe 中找相同/相似命中，合并为簇；相同档优先 |
| 种子反例 | 不得仅对 `seedAssetIDs` 调用闭包 `scan` 并宣称「全库查找」 |
| UI 入口 | 工具栏/工作台按钮：「分析当前筛选」「在图库瘦身中查找」；侧栏仍整页工作台 |
| 对比 UX | 簇内 `Set<UUID>` 选择；≥2 张并排 preview；无销毁按钮生效 |
| 读取安全 | 复用既有 fingerprint / FP / embedding / FD 路径；不触碰受保护真实库 |

## 4. 测试矩阵

1. 范围：仅带标签 A 的资产进入 `scan` 宇宙；标签外资产不入簇
2. 种子：种子 S 与库内近邻 T（注入向量或 fixture）→ 出现含 S+T 的簇；仅扫描种子集合不得作为本用例实现
3. 种子无命中 → 空簇或明确状态，不报假成功全库无相似
4. 簇成员多选：选中 2 个 ID 后对比集合可观察
5. destination 切换到瘦身后，种子入口会带入选中 ID
6. 源文件 snapshot 不变（若触及 fingerprint 路径）

## 5. 停止位置

S3 绿灯并本地提交后停止；不进入 S4 回收站。
