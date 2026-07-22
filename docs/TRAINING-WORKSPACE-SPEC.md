# ImageAll 训练工程工作区规格

> 状态：Approved（TW-P6/P7 由所有者授权默认方案，2026-07-22）  
> 日期：2026-07-22  
> 基线：`main@c10b022770c34f02c84b708fdb6c7b3e30f894d5`（撰写时 HEAD；实施开工前以文档提交后的精确 HEAD 为准）  
> 相关决策：ADR-038（训练 Run 与工程工作区）、ADR-039（三轨建议全并行与多槽激活）  
> 角色边界：本文定义范围、契约、验收门与切片顺序；可执行实现须另发 Cursor 交接单（临时授权期内可由 Codex 直接实施）

## 1. 目标

把三条原本分散在工具栏 / Review Overview / 后台 job 中的个人标签训练路径，升级为一等产品能力：

1. **每次训练 = 一条可审计的 `training_run`**（数据快照、配置、过程指标、产物指针、结果摘要）；
2. **前端独立「训练工程」大页**，可从图库主工作台切换进入；
3. **三套模型产物同时保留**，不因换用另一方案而删除磁盘 artifact 或历史 Run；
4. **Review Queue 全并行**：Feature Print、质心个人头、AdamW 个人头的待审建议可同时存在，用 origin 徽章区分。

本规格不改变：原图只读、人工事实优先、真实测试数据保护、默认不 push。

## 2. 已批准产品决策

| ID | 决策 | 状态 |
|---|---|---|
| TW-P1 | 三种训练方法进入统一工程叙事：`featureKnn`、`personalCentroid`、`personalAdamW` | 已批准（对话 2026-07-22） |
| TW-P2 | 每次训练写入详细工程记录（Run） | 已批准 |
| TW-P3 | 前端开辟独立训练工程空间（大页） | 已批准 |
| TW-P4 | 三套模型都保留，可随时对照；不为「进队列」而互顶删除 | 已批准 |
| TW-P5 | Review **全并行**：三轨建议都进队列，origin 徽章区分 | 已批准 |
| TW-P6 | 侧栏一级入口「训练工程」，进入后中央区切换为工程工作台 | **已批准**（所有者授权默认，2026-07-22） |
| TW-P7 | 工程页以**统一 Run 列表**为主，method 筛选/分组，不做「项目→Run」两层 | **已批准**（所有者授权默认，2026-07-22） |

未纳入本轮：`evaluation_assignment` 正式 train/val/test 归属、准确率仪表盘、云端训练、改写已批准 migration 历史。

## 3. 三种训练方法（产品名与代码映射）

| 产品名 | `method` | 现状入口 | 训练产物 | 建议落点 |
|---|---|---|---|---|
| 特征向量近邻 | `featureKnn` | Review「生成/更新」→ `personalization.fullLibrarySuggestions` | DB `tag_model*` + `prediction` | Feature Print 轨 |
| 个人模型（质心） | `personalCentroid` | 工具栏「重建个人模型」 | Application Support `PersonalModels/LinearHead/v1/` | 个人轨 · 质心槽 |
| 超级个人模型（AdamW） | `personalAdamW` | 工具栏「训练超级个人模型」 | Application Support `PersonalModels/AdamWHead/v1/` | 个人轨 · AdamW 槽 |

说明：

- 标准公共模型零样本推理**不是**本规格的训练工程对象；若出现在 Review，继续用既有 `standardModel` origin，不占用训练 Run。
- 历史 loopback HTTP 自动重训（`personalization.personalModelRebuild`）生产已关闭；本规格不以恢复 Python/HTTP 为前置。
- 代码中已有 `ReviewQueueSuggestionOrigin.personalAdamW` 与 AdamW 训练路径时，必须以本规格 ADR 补齐文档与数据契约，不得继续「无 Run、丢指标、单例互顶」。

### 3.1 样本门槛（按方法声明，UI 必须诚实展示）

| method | 可训练门槛（当前实现口径） |
|---|---|
| `featureKnn` | 每标签至少 `2` 确认 + `2` 不属于（既有 Review 文案） |
| `personalCentroid` | 每标签至少 `2` 确认样本；不强制负例（与 ADR-033 文档中的 `2 + 2` 存在漂移，本规格要求工程页**按实现门槛展示**，文档对齐另开修正，不在本轮静默改回） |
| `personalAdamW` | 与质心相同：每标签至少 `2` 确认样本 |

工程页发起训练前必须展示：范围内可训练标签数、样本计数、缺失 embedding/预览原因；失败不得破坏已 published 的其他槽位。

## 4. 信息架构

### 4.1 导航（TW-P6 已批准）

在 Sidebar「图库」区增加一级入口：

```text
图库
  全部照片
  无标签
  待审核建议
  训练工程          ← 新
来源
  …
标签
  …
```

选中「训练工程」后：

- 中央 Content **整页**切换为训练工程工作台；
- Inspector 可折叠；默认展示当前选中 Run 的摘要，无选中时展示「如何开始一次训练」；
- 工具栏保留既有快捷训练按钮，但每次动作必须写入/更新对应 `training_run`，并支持「在训练工程中查看」。

备选（若所有者否决侧栏）：顶栏「图库 | 训练工程」模式切换。语义相同，仅壳层不同；实施交接单以最终批准的 TW-P6 为准。

### 4.2 训练工程工作台布局

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ Toolbar: 发起训练 ▾ | 方法筛选 | 刷新 | 返回图库                            │
├────────────────────────────┬─────────────────────────────────────────────┤
│ Run 列表                   │ Run 详情                                     │
│ · 状态 / 方法 / 时间       │ 概览 · 数据 · 配置 · 过程 · 产物 · 结果      │
│ · 筛选：全部/三方法        │ 关联：打开 Review / 用该 Run 生成建议         │
│ · 槽位状态条（三轨 published）│                                              │
└────────────────────────────┴─────────────────────────────────────────────┘
```

### 4.3 三槽位状态条（全并行的用户可见锚点）

始终显示三轨是否有 **published** 产物：

| 槽位 | published 含义 |
|---|---|
| Feature Print | 至少一枚 active 标签存在 `tag_model.current_revision` |
| 质心 | `personalCentroid` 槽指向一次成功 Run / artifact |
| AdamW | `personalAdamW` 槽指向一次成功 Run / artifact |

「切换」在全并行产品语义下的含义：

- **不是**关掉另外两轨的队列可见性；
- **是**选择「下一次训练/建议生成默认落在哪条轨」、以及详情页高亮；
- 三轨只要有 pending 建议，Review 一律可同时看到。

## 5. Review Queue：全并行契约（TW-P5）

### 5.1 取代旧去重

`ARCHITECTURE` §11.3.2 曾规定：Feature Print 与 personal 对同一 `asset_id + tag_id` 重叠时「只显示一次并标记个人 DINO」。**本规格废止该去重**，改为全并行展示。

### 5.2 队列行身份

在标签内 Review Queue 中，投影主键为：

```text
(asset_id, tag_id, suggestion_origin)
```

其中本规格相关 origin 仅：

- `featurePrint`
- `personalModel`（质心；保持既有 raw value，避免无谓迁移 UI）
- `personalAdamW`

同一资产在同一标签下最多三条个人相关建议行（另加标准轨 `standardModel` 时仍按既有标准规格，不在此展开）。

`ReviewQueueItemProjection.id` 不得再仅用 `assetID`；必须能区分 origin（例如合成稳定字符串或增加 `origin` 参与 `Identifiable`）。

### 5.3 徽章与排序

- 每行显示单一 origin 徽章（文案见 §9）；
- 首版仍不展示原始 score / 百分比（延续阶段 3 批准）；对比靠「多行并存 + 徽章」，不靠分数条；
- 排序：同一标签内先按 `suggestion_origin` 稳定优先级，再 `score DESC, asset_id ASC`。  
  建议 origin 优先级（可配置常量，须测锁定）：`personalAdamW` → `personalModel` → `featurePrint` →（标准轨另定）。

### 5.4 人工决定与清除

人工事实仍唯一：`asset_tag_decision(asset_id, tag_id)`。

对任一 origin 行执行确认属于 / 不属于：

1. 写入同一条人工决定；
2. **清除该 `asset_id + tag_id` 下所有 origin 的 pending 建议**（含另外两轨）；
3. 撤销语义保持阶段 3：恢复先前人工决定；若各轨 model revision 未变，各 origin 建议可重新出现。

「稍后」只移动选择，不写库，三轨行均保留。

### 5.5 概览计数

「待审核建议」徽标与标签概览条数改为统计 **`(asset, tag, origin)` 行数`**，并在概览中按 origin 分列或提供筛选。不得把三轨折成一行后少计。

### 5.6 Inspector

普通 Inspector「AI 建议」列出该资产全部 pending `(tag, origin)`，同标签多 origin 并排显示徽章，禁止静默只留一条。

## 6. 数据契约

### 6.1 新表 `training_run`（逻辑模型；物理 migration 建议 v014）

| 列 | 约束 / 含义 |
|---|---|
| `id` | UUID PK |
| `method` | `featureKnn` \| `personalCentroid` \| `personalAdamW` |
| `state` | `queued` \| `running` \| `succeeded` \| `failed` \| `cancelled` |
| `created_at_ms` / `started_at_ms` / `finished_at_ms` | 非负；终态必须有 `finished_at_ms` |
| `catalog_scope_id` | 绑定当前目录库 |
| `job_id` | 可空；`featureKnn` 建议生成/训练关联 job 时填写 |
| `sample_summary_json` | 标签数、每标签正/负计数、范围（全库/多选）摘要；**不含**原图路径 |
| `sample_manifest_sha256` | 可选；完整样本清单另存对象文件时用内容哈希引用 |
| `config_json` | 超参与门槛（AdamW epochs/lr 等；质心策略 revision；Feature Print provider） |
| `metrics_json` | 过程指标；AdamW 必须持久化 epoch/val loss 曲线，禁止只留内存 |
| `artifact_kind` / `artifact_ref` / `artifact_sha256` | 产物指针（DB revision 或 Application Support 相对键） |
| `result_summary_json` | 成功标签数、样本数、是否 published、错误码 |
| `error_code` | 可空；结构化，不进自由文本堆栈 |

索引：`(method, created_at_ms DESC)`、`(state, created_at_ms DESC)`。

Run **不可变历史**：成功后不得因后续另一次训练而删除；失败/取消亦保留。

### 6.2 个人多槽激活（废止 singleton 互顶）

废止「`personal_suggestion_model.singleton = 1` 全局唯一」作为质心与 AdamW 的互斥点。

目标逻辑：

```text
personal_suggestion_model (
  method PRIMARY KEY  -- 'personalCentroid' | 'personalAdamW'
  , …既有 capability 身份列…
  , published_run_id  -- 可空 FK → training_run.id
)

personal_suggestion_tag (
  method, tag_id  -- PK 含 method
  , FK → personal_suggestion_model(method)
)

personal_prediction (
  method, asset_id, tag_id, content_revision  -- PK 含 method
  , score, state, created_at_ms
)
```

迁移要求：

- 现有单例行按 `bundle_id` 映射到对应 method 后写入新槽；
- 另一槽若无历史则为空；
- **禁止**再使用 `DELETE FROM personal_suggestion_model` 清空全部个人槽来激活其中一个；
- 激活某一 method 只 upsert 该 method 行，并只替换该 method 的 `personal_prediction`；
- 磁盘 `LinearHead` 与 `AdamWHead` 目录继续分离，与 DB 槽一一对应。

Feature Print 继续使用 `tag_model` / `prediction`，不写入 `personal_prediction`。

### 6.3 与 `job` 的关系

| method | 训练/重建 | 全库建议 |
|---|---|---|
| `featureKnn` | 模型 revision 写入与建议 job 可同属一次用户动作或拆成两次 Run（交接单须选定一种并测锁） | 既有 `personalization.fullLibrarySuggestions` |
| `personalCentroid` / `personalAdamW` | 首版可将「显式重建」升级为持久 job **或** 同步执行但强制写 Run；不得再出现「成功但无 Run / AdamW 指标丢弃」 | 各 method 独立建议生成，写入对应 `personal_prediction.method` |

活动 popover 继续展示 job；工程页以 Run 为权威历史。两者通过 `training_run.job_id` 关联。

### 6.4 样本清单存储

完整 `(tag_id, asset_id, content_revision, role)` 清单：

- 小规模可内嵌压缩 JSON（有硬上限）；
- 超过上限写入 Application Support `TrainingRuns/<run-id>/manifest.json`（原子发布），DB 只存 sha256；
- 清单不得包含 bookmark、原图像素或受保护真实照片路径。

## 7. 应用层行为

### 7.1 发起训练

统一入口（工程页 + 工具栏快捷）：

1. 解析范围（全库确认样本 / 当前多选上的确认标签）；
2. 创建 `training_run`（`queued`→`running`）；
3. 执行训练；指标写入 `metrics_json`；
4. 成功则发布该方法槽位 artifact，upsert 对应 `personal_suggestion_model`（仅该 method），`state=succeeded`；
5. 失败/取消不修改其他 method 槽位与 Feature Print `tag_model`。

### 7.2 生成建议（全并行）

用户可分别触发：

- Feature Print TopN / 全库；
- 质心 TopN / 全库；
- AdamW TopN / 全库。

三次生成的 pending 结果**共存**。同一 `asset+tag+method` 更新时只替换该 method 行。

### 7.3 失效规则

- 人工决定变化：该 `asset+tag` 所有 origin pending 在下次投影中消失（已有逻辑）；
- 某 method 重新 published：只清除/替换该 method 的可重建预测；
- catalog scope / encoder identity 不匹配：该 method fail closed，不影响其他 method 的 published 与 pending。

## 8. UI 文案（首版）

| 场景 | 文案 |
|---|---|
| 侧栏入口 | 训练工程 |
| Origin 徽章 Feature Print | 特征向量 |
| Origin 徽章质心 | 个人模型 |
| Origin 徽章 AdamW | 超级个人 |
| 槽位空 | 尚未训练 |
| 槽位已 published | 已就绪 |
| 全并行说明（空态） | 三种建议可以同时出现在待审核队列中，徽章标明来源；确认或拒绝一次即对该照片与标签生效。 |

## 9. 切片与停止位置

| 切片 | 交付 | 明确不做 | 停止 |
|---|---|---|---|
| **T0** | 本规格 + ARCHITECTURE ADR-038/039 文档提交 | 无代码 | TW-P6/P7 已批准；进入 T1 |
| **T1** | migration：`training_run` + 个人多槽 schema；读写契约与反例测试 | 无大 UI | 不改 Review 去重 |
| **T2** | 三方法训练路径写 Run；AdamW `metrics_json` 落盘；激活不再互顶 | 不改工具栏布局大改 | |
| **T3** | Review 全并行投影、徽章、计数、Inspector；`Identifiable` 含 origin | 不显示 score | |
| **T4** | 侧栏训练工程大页：列表 + 详情骨架 + 发起训练收拢 | 无图表大屏、无 evaluation_assignment | 端到端可演示后交 Codex 复审 |

每个切片单独 Cursor 会话与 `docs/cursor-cli-tasks/` 留档；不得与未关联的工作区脏改动混提。

## 10. 测试矩阵（实施必须覆盖）

1. 质心成功 published 后训练 AdamW：两槽均在，质心 artifact 与预测仍在；
2. 三轨对同一 `asset+tag` 各有 pending：队列出现三行三徽章；确认一行后三行皆清除且人工决定正确；
3. AdamW 训练结束后 `metrics_json` 含可解析 epoch 曲线；进程重启可从 DB 读回；
4. Feature Print job 关联 `training_run.job_id`（若 T1 选定关联策略）；
5. 某 method identity mismatch 只失效该 method；
6. 工程页列表按 method 筛选与按时间排序；
7. 回归：人工事实不被预测覆盖；原图只读；不触碰受保护真实照片路径。

## 11. 验收门

- 文档：ADR-038/039 已写入 `ARCHITECTURE.md`，本文件路径被引用；
- T1–T4 各自：Debug 构建通过、相关测试通过、工作区干净、作者归属符合 `AGENTS.md`；
- 可观察行为（T4）：能从侧栏进入训练工程，看到至少一次 Run 详情，并在 Review 看到至少两种 origin 徽章并存（三轨全齐更佳）。

## 12. 风险与技术债

| 风险 | 缓解 |
|---|---|
| 队列噪音变大 | 全并行为已批准；后续可加 origin 筛选，不挡 T3 |
| ADR-033 `2+2` 与质心实现门槛漂移 | 工程页按实现展示；另开文档修正 ADR-033 或收紧实现 |
| 工作区已有未提交 AdamW 代码 | 规格不混入该 diff；实施以干净基线或所有者明确归属的提交为准 |
| `ReviewQueueItemProjection.id` 变更 | 破坏性 UI 身份变化，测试必须更新选择/撤销路径 |

## 13. 回传清单（供后续 Cursor 交接单引用）

实施方交付时须回传：

1. migration ID 与 schema 期望测试；
2. 三槽并存与互不 `DELETE` 全表的测试名；
3. 全并行队列三行/徽章/确认级联清除的测试名；
4. AdamW metrics 落盘测试名；
5. 训练工程页入口与 Run 详情截图或 UI 测试；
6. `git show` 归属与 Codex 复审材料。
