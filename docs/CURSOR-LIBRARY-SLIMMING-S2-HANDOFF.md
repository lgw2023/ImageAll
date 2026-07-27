# Cursor 交接单：图库瘦身 S2（相似聚类 + 侧栏只读浏览）

> 状态：Ready  
> 日期：2026-07-27  
> 权威规格：[`LIBRARY-SLIMMING-SPEC.md`](LIBRARY-SLIMMING-SPEC.md) §7 S2；[`ADR-044-LIBRARY-SLIMMING-AND-RECYCLE.md`](ADR-044-LIBRARY-SLIMMING-AND-RECYCLE.md)
> 上一批准基线：`main@a9cef7e41dfc33084afd58fa8d3cfe6729bca8dc`（含 S1 交付与后续无关 R0 文档）  
> 角色：临时授权期内可由本会话直接实施；交付 commit 使用实施身份与 `Agent-Role: implementation`

## 1. 范围

交付只读「相似」档与侧栏工作台：

1. Feature Print 粗筛召回（Top-K + 宽松 L2 半径）+ DINOv2 余弦精排；
2. 与 S1 相同档组合：`byteIdentical` / `perceptualDuplicate` 优先，剩余资产进入 `nearDuplicateScene`；
3. 版本化阈值写入 `NearDuplicateScenePolicy`（禁止散落魔法数）；
4. 缺 Feature Print / DINOv2 的资产标为「待分析」，不得伪装成无相似；
5. 侧栏「图库」区在「训练工程」旁增加「图库瘦身」；选中后整页切换为只读簇浏览工作台（对齐训练工程模式）；
6. 工作台可对当前库可用资产发起分析，展示相同簇优先、其次相似簇；簇内缩略图只读；
7. 合成 fixture / 注入向量单元测试证明：粗筛召回、精排阈值边界、相同优先、待分析、源文件不变。

## 2. 明确不做

- 种子图 / 标签范围入口（S3）
- 簇内多选对比 UX 深化、移入回收站按钮生效（S3/S4）
- 任何原图 rename / copy / delete / PhotoKit mutation（S4+）
- `similarity_cluster_run` 持久化 migration（可延后；S2 允许内存分析结果）
- 全库可恢复 Job（S2 同步/off-main 分析即可；大库 Job 归 S6）
- 阈值设置 UI、性能分桶

## 3. 契约要点

| 项 | 值 |
|---|---|
| 相似 kind | `nearDuplicateScene` |
| FP 召回 | Top-K = 16；L2 半径上限写入政策常量 |
| DINOv2 精排 | 余弦相似度 ≥ `τ_sim`（政策常量，随 `policyVersion`） |
| 模型身份 | 结果须携带 FP provider/revision 与 DINOv2 encoder 身份字段（或政策版本串） |
| 相同优先 | 已入相同簇的成员不得再入相似簇 |
| UI | 无销毁性操作；可显示「回收站即将推出」只读提示 |
| 读取安全 | 复用既有 Feature Print / embedding / folder FD 路径；不直写受保护真实库 |

## 4. 测试矩阵

1. 注入向量：两资产 FP 近邻且 DINO 余弦 ≥ τ → 一簇 `nearDuplicateScene`
2. FP 召回命中但 DINO 低于 τ → 不成相似簇
3. 字节/感知相同簇成员不出现在相似簇
4. 缺 embedding → `pendingAnalysis`，不报「无相似」空簇冒充
5. 分析后源文件 snapshot 不变
6. 侧栏 destination / 工作台展示至少一条模型级或 UI 契约测试（destination 切换不进普通网格筛选态）

## 5. 停止位置

S2 绿灯并本地提交后停止；不进入 S3 种子入口 / 对比 UX，不进入回收站。
