# Cursor 交接单：图库瘦身 S6（可配置阈值 + 大库分桶）

> 状态：Delivered  
> 日期：2026-07-27  
> 权威规格：[`LIBRARY-SLIMMING-SPEC.md`](LIBRARY-SLIMMING-SPEC.md) §4 / §7 S6；[`ADR-044-LIBRARY-SLIMMING-AND-RECYCLE.md`](ADR-044-LIBRARY-SLIMMING-AND-RECYCLE.md)
> 上一批准基线：`main@1d97535158be1ae910715a110fe713403dd72a1f`（S5 闭环 + 来源归属策略对齐）  
> 开工文档基线：`main@edeb11e73672bf51ea893521c722f10ae2ef3e3d`  
> 角色：临时授权期内可由本会话直接实施；交付 commit 使用实施身份与 `Agent-Role: implementation`

## 1. 范围

在 S0–S5 已关闭 MVP 验收门之后，交付可选性能/可调切片的**最小纵切**：

1. **可配置阈值**（版本化，禁止魔法数散落）：
   - 将 `NearDuplicateScenePolicy` 的 `featurePrintRecallTopK` / `featurePrintMaxL2Distance` / `dinoCosineMinSimilarity` 提升为可注入的 `NearDuplicateSceneThresholds`；
   - 工厂默认值保持现有常量；用户覆盖经偏好存储持久化（UserDefaults 即可，**不**要求新 migration）；
   - 分析结果的 `policyVersion` 必须编码当前生效阈值，改阈值后结果可解释；
   - 感知近重复 Hamming 阈值可一并暴露（可选，默认仍读 `IdenticalDuplicatePolicy`）；
2. **大库分桶**：当闭宇宙（catalog / currentFilter）参与场景聚类的资产数 ≥ 激活门槛时，按 `media_created_at_ms` 的**本地日历日**分桶，仅在桶内做 Feature Print 召回 + DINOv2 精排；无拍摄时间的资产进入共享 `unknown` 桶；
3. **相同档仍全局**：`byteIdentical` / `perceptualDuplicate` **不分桶**，避免跨日拷贝漏检；
4. **种子模式不分桶**：`scanSeeds` 继续对宇宙做查询式召回（已是 Top-K，非全对全团簇），避免种子跨日近邻被切掉；
5. **增量语义（本切片）**：继续依赖既有 content-revision 指纹 / Feature Print / embedding 缓存命中，不重复昂贵生成；**不**新增 `similarity_cluster_run` 持久化；
6. **UI**：瘦身工作台提供「相似度阈值」入口（popover / 折叠区均可），可调 τ_sim、Top-K、L2 半径、分桶激活门槛，并提供「恢复默认」；改完提示「下次分析生效」；
7. **测试**：阈值抬高后原先成簇对拆散；大库分桶下不同日资产不进同一场景簇；同日仍可成簇；相同档跨日仍合并；工厂默认回归；种子路径不因分桶漏召回。

## 2. 明确不做

- `similarity_cluster_run` / `similarity_cluster_member` 持久化 migration
- 全库可恢复 Job Queue（分析仍可同步 / off-main Task）
- 自动静默调参、跨设备同步阈值
- 改写已批准 migration V001–V021
- 任何新的原图销毁路径 / PhotoKit mutation 扩展
- 读取或修改 `/Volumes/HDD2` 受保护真实数据

## 3. 契约要点

| 项 | 值 |
|---|---|
| 工厂默认 | TopK=16，L2≤25.0，DINOv2 cosine≥0.88，分桶激活≥256 |
| 偏好键前缀 | `library.slimming.thresholds.v1.*` |
| `policyVersion` | 含 `near-dup-scene-v1` + 生效阈值摘要 |
| 分桶键 | `YYYY-MM-DD`（本地日历）或 `unknown` |
| 相同档 | 全局，不受分桶影响 |
| 种子扫描 | 不分桶 |

## 4. 测试矩阵

1. 默认阈值下既有场景聚类用例仍绿
2. 提高 `dinoCosineMinSimilarity` → 边界对不再成簇
3. 资产数 ≥ 激活门槛且分属两天 → 不形成跨日 `nearDuplicateScene` 簇
4. 同日两张高相似 → 仍成簇
5. 跨日字节相同 → 仍 `byteIdentical`
6. 种子扫描：种子与异日宇宙成员在阈值内仍可命中
7. 恢复默认写回工厂值

## 5. 停止位置

S6 绿灯并本地提交后停止；**不**开启簇结果持久化或下一阶段能力。图库瘦身可选性能切片在此关闭。
