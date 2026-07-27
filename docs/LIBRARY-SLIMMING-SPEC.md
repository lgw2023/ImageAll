# ImageAll 图库瘦身规格

> 状态：Implemented（所有者批准 LS-P1…P9，2026-07-27）
> 日期：2026-07-27  
> 基线：撰写时 `main@adc81917ca29ca022f38f797b2c957934bee3db4`；实施开工前以文档提交后的精确 HEAD 为准  
> 权威决策：[`ADR-044-LIBRARY-SLIMMING-AND-RECYCLE.md`](ADR-044-LIBRARY-SLIMMING-AND-RECYCLE.md)
> 角色边界：本文定义范围、契约、验收门与切片顺序；可执行实现须另发 Cursor 交接单（临时授权期内可由 Codex 直接实施）

## 1. 目标

提供一等产品能力「图库瘦身」：

1. 找出**相同**照片（字节相同，或转码/拷贝后像素几乎全等）；
2. 找出**相似**照片（同场景 / 地点 / 连拍等真实不同照片）；
3. 按相似度聚类、排序，支持自由选择与对比；
4. 用户确认后默认移入回收站：文件夹资产由 ImageAll 保留 30 天后永久删除，Photos 资产遵循 macOS「照片」App 的系统回收策略；
5. 覆盖文件夹来源与 Apple Photos，但物理回收分轨（见 ADR-044）。

本规格**不**改变：标签双轨、人工事实优先、真实测试数据保护、默认不 push。本规格**局部修订**：原图默认只读，仅瘦身确认路径可回收/删除。

## 2. 已批准产品决策

| ID | 决策 | 状态 |
|---|---|---|
| LS-P1 | 范围含文件夹 + Apple Photos | 已批准 |
| LS-P2 | 文件夹使用 App quarantine + DB 倒计时 | 已批准 |
| LS-P3 | 相同 = SHA-256 + 感知近重复 | 已批准 |
| LS-P4 | 相似 = Feature Print 粗筛 + DINOv2 精排 | 已批准 |
| LS-P5 | 授权文件夹资产：用户确认后移入回收站 / 到期永久删除 | 已批准 |
| LS-P6 | Photos 仅经公开 PhotoKit 移入系统「最近删除」；恢复、保留期限和永久删除由 macOS「照片」App 管理；不进 App quarantine | **所有者批准（2026-07-27）** |
| LS-P7 | 禁止自动删除；所有销毁性动作需确认 | **本规格锁定** |
| LS-P8 | Photos「相同」检测遇到 iCloud-only 资产时隐式下载原始内容，并在 App 内长期保存 | **所有者批准（2026-07-27）** |
| LS-P9 | 大图库分析支持持久化暂停、续跑、启动恢复和自动补全 | **所有者批准（2026-07-27）** |
| LS-P10 | 用户可对单个来源显式「初始化相似索引」（Feature Print LSH 邻域 + 桶内软簇） | **所有者批准（2026-07-28）**；见 ADR-045 |
| LS-P11 | 种子检索在宇宙来源索引就绪时只比对邻域候选，否则回退全宇宙粗筛 | **所有者批准（2026-07-28）**；见 ADR-045 |

未纳入本轮：人脸身份合并、以图搜视频、NAS 来源、云端去重、自动保留策略（如「一律留最大分辨率」）的无人值守执行、跨来源自动后台预热。

## 3. 信息架构

### 3.1 侧栏

在 Sidebar「图库」区、`训练工程` 旁增加：

```text
图库
  全部照片
  无标签
  待审核建议
  训练工程
  图库瘦身          ← 新
  回收站            ← 可与瘦身同页 Tab，或同区二级入口；首版允许做瘦身页内 Tab
```

选中后中央 Content **整页**切换为瘦身工作台（模式对齐训练工程，不复用普通网格筛选态冒充）。

### 3.2 瘦身工作台主路径

```text
（可选）选中单个来源 → 初始化相似索引（可暂停/恢复）
选择范围（标签/来源/当前筛选）或种子照片（1..N）
        → 运行分析 Job（可暂停/恢复；种子检索优先走来源邻域索引）
        → 簇列表（相同簇优先，其次相似簇）
        → 进入簇：缩略图网格 + 大图对比 + 多选
        → 标记保留 / 移入回收站
        → 确认执行
        → 回收站显示来源对应的时间与动作
           ├─ 文件夹：可恢复 / 立即永久删除
           └─ Photos：在「照片」App 恢复；系统管理永久删除
```

### 3.3 查询入口

| 入口 | 行为 |
|---|---|
| 基于范围 | 使用当前标签、来源、媒体类型等过滤后的资产宇宙做全对全/分桶聚类 |
| 基于种子 | 以选中资产为 query，在全库（或用户收窄的来源）检索相同/相似，再把命中项与种子并成簇 |

种子可从图库主网格多选后「在图库瘦身中查找」，或在瘦身页内挑选。

## 4. 相似度契约

### 4.1 档位

| 产品档 | 内部 kind | 定义 |
|---|---|---|
| 相同 | `byteIdentical` | `sha256` 相等且非空 |
| 相同 | `perceptualDuplicate` | 哈希未命中，但感知近重复分数 ≤ 版本化阈值 `τ_dup` |
| 相似 | `nearDuplicateScene` | Feature Print 召回且 DINOv2 精排分数 ≥ 版本化阈值 `τ_sim`，且未进入相同档 |

同一资产不得同时以「相同」与「相似」出现在两个档；相同优先。

### 4.2 算法流水线

1. **准备**：补全缺失 `sha256`、感知指纹、Feature Print、DINOv2 embedding（content-revision 感知缓存）。
2. **相同 · 字节**：`sha256` group by。
3. **相同 · 感知**：在未归入字节簇的资产上，dHash v2 只做候选召回；候选必须再通过宽高比约束和
   归一化 `16 × 16 RGB` 像素签名距离校验，并用 complete-link 保守成簇，禁止用单纯连通分量造成链式误合并。
4. **相似 · 粗筛**：Feature Print 余弦/距离召回 Top-K 或半径候选。
5. **相似 · 精排**：对候选算 DINOv2 余弦相似度，按 `τ_sim` 与连通分量/层级聚类成簇。
6. **排序**：簇按「风险/收益」排序（默认：成员数降序，再按最高相似度）；簇内按与代表图的相似度降序。代表图默认取最高分辨率或用户已选「保留」标记。

阈值、模型身份、预/后处理身份必须进入结果版本；embedding 未就绪的资产显示「待分析」，不假装「无相似」。

### 4.3 反例

- 不得仅用文件名/拍摄时间差宣称相同。
- 不得在 DINOv2 未跑完时用 Feature Print 分数冒充精排结果持久化。
- 不得跨 `content_revision` 复用旧向量而不校验缓存键。

### 4.4 Photos iCloud-only 原始内容

- 仅在「图库瘦身 → 相同检测」需要内容指纹、且本地没有可用原始内容时，PhotoKit Adapter 才隐式允许网络下载；
- 请求使用原始版本和高质量交付，不把 2048px 标准预览当成原图，也不把派生预览写入长期原图索引；
- 成功字节原子写入 App Application Support 的 `Photos Originals/v1`，作为长期可用产品数据，不受
  512 MiB 下载预览 LRU 自动淘汰；
- DB 索引绑定 `asset_id`、`content_revision`、`photos_local_identifier`、媒体类型、字节数与
  编码内容 SHA-256；资产版本或 locator 变化、文件缺失或校验失败时 fail closed 并重新获取；
- App 不写回 Photos、不把副本导入 Photos，也不把长期副本冒充 ImageAll 回收站对象。
- 长期原图默认无限期保留，不设置 TTL、容量驱逐或自动清理；存储面板显示独立数量和字节数。
- 用户可在二次确认后清除全部长期原图。`pending` / `running` 分析期间入口拒绝执行；清理只删除
  Application Support 内已登记且通过根目录、UUID 对象名、常规文件和非符号链接校验的副本及索引，
  不删除 Photos 资产、人工标签、指纹或既有分析结果。以后再次分析时允许重新下载。

这项产品授权不等于对 HDD2 受保护真实图库的测试授权。真实 smoke 是否允许触发下载仍按
`LOCAL-TEST-DATA-SAFETY.md` 的单次 `CloudDownloadGrant` 执行。

## 5. 回收站契约

### 5.1 文件夹轨道

1. 用户确认「移入回收站」。
2. 事务意图先写入 DB（`recycle_entry` pending）。
3. 同卷：目录 FD / no-follow 安全语义下 `rename` 进 quarantine；跨卷：完整复制数据、权限、扩展属性与文件时间 → 刷盘 → 校验目标和源文件仍未变化 → 删除源（任一步失败都不得删源）。
4. 成功后 asset `availability`/locator 进入 `recycled` 状态；主图库浏览默认隐藏。
5. `purge_after_ms = trashed_at_ms + 30d`。
6. 恢复：逆移回原 `relative_path`；目标存在则失败并保持回收站。
7. 到期或用户「立即删除」：删除 quarantine 对象，级联清理派生物与索引。

Quarantine 根位于 App 容器内（Application Support），按 source/asset 分片；不写回用户相册目录旁的隐藏文件夹。

### 5.2 Photos 轨道

1. 需要 Photos 写入授权；否则拒绝执行并说明。
2. 经 PhotoKit 将资产移入系统「最近删除」。
3. ImageAll 写 `recycle_entry`（`kind=photos`，保存 `photos_local_identifier`）。
4. 公开 PhotoKit 只能可靠区分「当前图库可见」与「当前不可见」，不得使用未公开的「最近删除」相册 subtype 猜测更细状态。
5. 用户只能在 macOS「照片」App 恢复或永久删除；ImageAll 检测到资产重新可见时恢复本地 catalog 状态。
6. `purge_after_ms` 只控制 ImageAll 本地回收记录的清理时间；到期收敛不得表述为系统永久删除，也不得触发第二次 PhotoKit 删除。
7. **禁止**把 Photos 像素导出到 App quarantine 再删库内项。

### 5.3 UI

- 回收站列表：缩略图、来源徽章、原文件名/标识与来源对应的时间提示。
- 文件夹条目显示永久删除倒计时，并提供恢复、立即删除；不足 24h 显示小时，否则显示天。
- Photos 条目显示「ImageAll 将在 N 天/小时后清理此记录」和「恢复说明」，明确提示实际恢复与永久删除由 macOS「照片」App 管理；不显示 ImageAll 立即删除按钮。
- 文件夹批量恢复/永久删除需二次确认，文案含数量与不可撤销警告（仅永久删除）。

## 6. 数据模型（逻辑）

逻辑实体（名称为契约，非强制最终 SQL 标识符）。仓库现已使用 **v022** 完成本轮加固，不再使用文内早期草稿的 “V005” 称呼。

- `recycle_entry`：id, asset_id, source_kind(`file`/`photos`), trashed_at_ms, purge_after_ms, state(`pending`/`recycled`/`restored`/`purged`/`failed`), quarantine_relative_path?, photos_local_identifier?, error_code?
- `asset_similarity_fingerprint`：asset_id, content_revision, algo_version, perceptual_hash,
  content_sha256, verification_signature, pixel_width, pixel_height
- `photos_original_cache_entry`：长期 Photos 原图的 asset/revision/local identifier、对象名、媒体类型、字节数、SHA-256 与时间
- `library_slimming_scan_member`：按 Job 冻结的资产宇宙、稳定 ordinal 与 seed 标记
- `library_slimming_scan_result`：分析 Job 的版本化 JSON 结果；与 Job 完成状态原子提交

具体 DDL、CHECK、STRICT 与 FD 安全细节在切片交接单中冻结；本规格只锁语义。

## 7. 切片顺序（纵向闭环）

| 切片 | 交付 | 停止位置 |
|---|---|---|
| **S0** | ADR/本规格入库；`ARCHITECTURE.md` / Photos 安全表述同步；测试数据安全说明补充瘦身例外不等于测试授权 | 无生产代码 |
| **S1** | 文件夹 SHA-256 补全 + 感知近重复；只读 API/测试；无可疑 UI 可先用最小调试入口或纯测试证明 | 不删原图 |
| **S2** | Feature Print 召回 + DINOv2 精排聚类服务；侧栏「图库瘦身」只读浏览簇 | 不删原图 |
| **S3** | 种子图 / 标签范围两种入口；簇内多选对比 UX | 不删原图 |
| **S4** | 文件夹 quarantine 回收站 + 倒计时 + 恢复 + purge Job | 不含 Photos 写入 |
| **S5** | Photos PhotoKit 软删除 + 系统恢复说明 + 本地对账；统一回收站 UI | 全能力最小闭环 |
| **S6** | 性能：大库分桶、增量、阈值可配置（若 S2–S5 已够用可延后） | — |
| **S7** | 跨来源原始内容 SHA-256、dHash v2 + RGB 校验、Photos iCloud-only 长期原图 | 不访问受保护真实图库 |
| **S8** | 冻结成员集的持久分析 Job、暂停/续跑/启动恢复、最多 3 轮自动补全、原子结果发布 | 聚类阶段结束后响应暂停 |

每个切片单独交接、单独 commit 边界；不得跨切片提前引入销毁性 API，除非该切片验收门明确要求。

## 8. 测试矩阵（总览）

| 主题 | 必须证明 |
|---|---|
| 相同 | 字节相同成簇；转码近全等进 perceptualDuplicate；不同场景不进相同档 |
| 相似 | 粗筛召回含真近邻；精排阈值边界；缺 embedding 显示待分析 |
| 文件夹回收 | 同卷 rename、跨卷 copy+校验、恢复冲突、到期 purge、失败不丢源 |
| Photos 回收 | 仅公开 PhotoKit 软删除路径；无 `.photoslibrary` 直写；无私有「最近删除」探测；无 ImageAll 永久删除；授权拒绝；崩溃恢复与对账收敛 |
| Photos 原图 | iCloud-only 允许网络原始请求；长期对象原子发布；revision/local identifier/SHA 失配拒绝；派生预览不能伪装成原图 |
| 大库续跑 | 入队与冻结成员集原子；批次 checkpoint；暂停/继续；重启接管；待分析成员最多自动补全 3 轮；完成状态与结果原子 |
| 安全 | 非瘦身代码路径零删除；保护路径零触及；sentinel 文件保留 |
| 回归 | 既有 catalog/标签/训练/派生缓存测试保持绿灯 |

所有自动化用例使用临时 fixture；禁止挂载受保护真实库做删除测试。

## 9. 验收门（阶段完成定义）

阶段「图库瘦身 MVP」完成当且仅当：

1. 侧栏可进入工作台，范围与种子两种查询可用；
2. 相同/相似分档聚类可观察，分数与版本可解释；
3. 文件夹资产可确认进回收站、恢复、到期或立即永久删除，倒计时正确；
4. Photos 资产可经公开 PhotoKit 进入系统「最近删除」，统一 UI 如实说明系统托管的恢复/永久删除，本地记录对账正确；
5. Debug 测试目标可完整构建；在不会启动 production Photos 宿主的隔离环境中完成单元/运行验证；
6. 文档与实现一致，且真实数据保护规则未被削弱。

## 10. 风险

| 风险 | 缓解 |
|---|---|
| 误删宝贵原图 | 默认软删、确认文案、倒计时、恢复；禁止自动删 |
| Photos 权限/对账漂移 | 显式授权门；只使用公开可见性；以 Photos 系统策略为真相源 |
| 跨卷双份占用或元数据损失 | 完整元数据复制、文件与目录刷盘、最终源复核；校验前不删源 |
| 大库计算成本 | Job 可恢复；先哈希/FP 缓存命中；DINOv2 仅候选精排 |
| 假阳性合并 | 分档、阈值版本化、用户最终确认 |
| iCloud 长期副本占用 | 明确写入 Application Support 且不自动淘汰；存储面板显示用量并提供二次确认的全量手动清理 |

## 11. 停止位置（当前）

S0–S8 已交付。当前大库分析会冻结资产宇宙、持久化 checkpoint 和最终结果，支持 UI 暂停/继续、
App 重启后自动接管，并对待分析成员最多执行 3 轮自动补全。暂停在安全边界生效：指纹阶段为单资产、
向量阶段为 16 个资产；已进入聚类时在本轮聚类完成后响应。

2026-07-27 经项目所有者单次 `CloudDownloadGrant`，受保护真实 Photos Library 完成 PhotoKit-only
云端下载 smoke：由一个经用户确认的 iCloud-only 资产触发，分析任务冻结 50,641 个成员；首次在
210 个完成单元处安全暂停，继续后在 236 个完成单元处再次暂停，错误数为 0。长期原图聚合记录由
smoke 前的 1 份增长为 84 份、总计 1,437,540,765 字节；退出并重启 App 后 checkpoint、暂停态、
数量与字节数保持不变，界面仍提供「从已保存进度继续，并自动补全剩余照片」。本证据不包含资产标识、
文件名、内容或真实图库路径，也未执行 Photos 写入、删除 smoke 或长期原图手动清理。
