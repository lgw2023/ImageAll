# 训练工程工作区 T2

## 任务状态

- 状态：T2 已完成并由 Codex 自审通过（2026-08-13 前临时实施授权）
- 开工日期：2026-07-23
- 当前切片：仅 T2；完成并复审后停止，不进入 T3 / T4
- Cursor CLI：本切片未使用；无 Cursor session / `system/init.model` 证据

## 权威交接单 / 规格

- [`docs/TRAINING-WORKSPACE-SPEC.md`](../TRAINING-WORKSPACE-SPEC.md)（唯一产品权威）
- [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) ADR-038 / ADR-039
- [`docs/SUGGESTION-THRESHOLD-SPEC.md`](../SUGGESTION-THRESHOLD-SPEC.md) ADR-040 交叉约束
- [`docs/LOCAL-TEST-DATA-SAFETY.md`](../LOCAL-TEST-DATA-SAFETY.md)
- [`AGENTS.md`](../../AGENTS.md)
- [`.cursor/rules/codex-review-handoff.mdc`](../../.cursor/rules/codex-review-handoff.mdc)

## 上一批准基线

- T0 文档：`81a3201c601c662d067ab73e70eec1ef83bb2548`
- T1 schema / repository：`9fd5bb1d3d5d7c1fc926121f99c3df1254c32c53`
- T2 现场审计 HEAD：`0a76f9bed131ec243eaedb1f09f8c57faf4a3ba2`
- 分支：`main`
- 现场关系：`HEAD == origin/main`

## 开工 HEAD 确定规则

1. 本记录先以 Codex 文档身份单独提交。
2. 该文档提交后的精确 `git rev-parse HEAD` 是 T2 可执行实现的 `LAUNCH_HEAD`。
3. 后续结果补记不得与 Swift / 测试实现混入同一 commit。

## 现场工作区边界

开工审计显示已跟踪工作区干净；以下既存未跟踪目录不属于 T2，禁止 stage、删除、移动或覆盖：

- `.derivedData-*`
- `.wip-adamw-backup/`
- `.wip-t1-freeze/`
- `.wip-threshold-applied/`
- `.wip-threshold-backup/`

若后续出现来源不明且与 T2 文件重叠的改动，立即停止修改并报告；不得 `reset`、`checkout`、`stash` 或 `clean`。

## 已冻结的 T2 关联策略

### Feature Print / `featureKnn`

- 一次用户显式 `personalization.fullLibrarySuggestions` 入队动作对应一条 `training_run`。
- Run 与持久任务使用同一个 `job_id`；入队与 Run 创建必须在同一数据库事务中完成。
- Run 生命周期跟随 job：`queued` → `running` → `succeeded | failed | cancelled`。
- 成功产物指针指向本次 `tag_model_revision`；后续 Run 不删除历史 Run。

### 质心 / AdamW

- 样本和缓存预检通过、真正开始训练时创建 Run；Run 随即从 `queued` 进入 `running`。
- 成功发布磁盘 artifact 后，只激活对应 method 槽，并把该槽的 `published_run_id` 指向本 Run。
- 槽激活与 Run 成功终态使用同一数据库事务；失败或取消不得修改另一方法槽、另一方法预测或 Feature Print 表。
- AdamW `metrics_json` 持久化逐 epoch validation loss 曲线；进程重启后通过 `GRDBTrainingRunRepository.fetch` 读回。

## 当前范围

1. 三方法训练路径写 `training_run`：`featureKnn`、`personalCentroid`、`personalAdamW`。
2. 全生命周期：`queued` → `running` → `succeeded | failed | cancelled`，终态写 `finished_at_ms`。
3. `sample_summary_json`、`config_json`、`metrics_json`、artifact 指针和 `result_summary_json` 使用结构化 JSON / 相对键；不含原图路径、bookmark、照片 local identifier 或受保护路径。
4. AdamW report 增加逐 epoch validation loss 并持久化。
5. 个人槽激活写 `published_run_id`，仅替换当前 method 的槽和预测。
6. Run 记录追加保留，后续训练不得删除历史 Run。

## TDD 纵向测试矩阵

按“一条行为测试先失败 → 最小实现通过 → 下一条”的顺序执行：

1. AdamW trainer 对每个实际 epoch 返回有限 validation loss 曲线。
2. AdamW 重建成功后 Run 可由新 repository 实例读回，`metrics_json` 曲线可解析，且 `published_run_id` 指向该 Run。
3. 质心已 published 后再训练 AdamW：两槽均存在，质心 artifact / `published_run_id` / 预测保持不变。
4. 个人训练失败或取消：本 Run 正确终止，已 published 的其它槽与 Feature Print 模型不变。
5. Feature Print 入队与 Run 原子关联同一 `job_id`；执行后 Run 成功并指向本次 DB revision。
6. Feature Print 失败 / 取消能形成带 `finished_at_ms` 的失败 / 取消 Run，既有个人槽不变。
7. 回归：人工事实不被 prediction 覆盖；生产与测试代码无受保护真实照片路径字面量；测试只用独立临时数据库和合成 embedding。

## 验收命令与安全边界

- 定向测试、完整非宿主 XCTest、Debug build 和 `git diff --check` 都必须给出实际命令、退出码与计数。
- 受保护图库挂载期间禁止启动 production App 测试宿主；测试构建后使用直接 XCTest 执行路径，宿主身份专属用例按既有门禁单独标明，不得把环境失败伪装成产品失败。
- 所有 DerivedData / xcresult / 临时数据库写入任务专用临时目录或仓库既存排除目录；不得写入 `/Volumes/HDD2`。
- 不访问、枚举或探测 `/Volumes/HDD2/Photos Library.photoslibrary` 及年份目录。

## 明确不做

- 不改 Review 去重、origin 身份、徽章、计数或 Inspector（T3）。
- 不做侧栏「训练工程」大页或大改工具栏（T4）。
- 不做 `evaluation_assignment`、准确率仪表盘、云端训练。
- 不改写 v014 / v015，不新增 migration，除非实现证明现有 schema 无法满足 T2；若必须新增只能从 v016 起并先停下报告。
- 不 push、不 amend、不 squash、不改写 Git 历史。

## 停止位置

相关测试、完整非宿主回归、Debug build、Git 边界和照片安全审计通过后，创建窄范围 Codex 实现 commit；再以独立文档 commit 补记复审证据。明确结论必须是：**T2 完成，未进入 T3**。

## Codex 直接实施归属

- 文档 commit：`Codex <codex@openai.com>`，`docs(codex): ...`，`Agent-Role: product-architecture`
- 实现 commit：`Codex <codex@openai.com>`，`feat(codex): ...` 或 `fix(codex): ...`，`Agent-Role: implementation`
- 禁止 `Co-authored-by`；文档与实现不得混在同一 commit。

## 执行结果

### 基线与提交

- 初次现场审计：`0a76f9bed131ec243eaedb1f09f8c57faf4a3ba2`
- 审计后并行合入且已推到 `origin/main` 的无冲突提交：
  `9320db7cd14bb75b397a69c8aed599f7b6f6f0a6`
  （仅 `.gitignore` 忽略本地 DerivedData / wip 目录）
- 文档开工提交 / `LAUNCH_HEAD`：
  `3bc8e13bd370ee636cf0c35038a48633325bc924`
- T2 实现提交：`b0ffda2ff6bcc636c9068f075c4856aa459ff444`
- 分支：`main`
- Cursor CLI：未使用；session ID 与 `system/init.model` 均为 N/A。依据
  `AGENTS.md` 的临时直接实施授权，本切片由 Codex 实现并以
  `Agent-Role: implementation` 归属。

### 已交付行为

1. `featureKnn` 的 job 与 Run 在同一事务创建并共享 `job_id`；执行开始写
   `running`，发布 revision 与 `succeeded` 同事务完成，取消 / 终止失败均
   留下带 `finished_at_ms` 的不可变 Run。
2. `personalCentroid` 与 `personalAdamW` 显式重建都写 Run；所用首份样本快照
   同时作为审计摘要和实际训练输入，训练前后仍做 live snapshot 陈旧检查。
3. AdamW report 持久化实际 epoch 序号与 validation loss 曲线；新的 repository
   实例可在进程重启语义下读回。
4. 成功发布采用同一事务更新对应 method 槽的 `published_run_id` 与 Run 终态；
   激活改为按 method upsert，只删除当前 method 的标签 / 预测，不删除另一槽。
5. 失败 Run 保留结构化 `error_code`，不切换任何已发布槽；后续 Run 不删除历史。
6. 同步修正两项已经落地但测试仍停留在旧契约的夹具：Review projection 允许
   ADR-040 已要求的 `score`，migration replay 会正确移除并重放 v015 测试表；
   未修改 v014 / v015 生产 migration。

### 测试与构建证据

- TDD RED：AdamW report 无 `epochMetrics` 时测试编译失败；Feature Run 入队时
  `0 != 1`；完成 / 取消后 Run 仍为 `queued`；随后逐项最小实现转绿。
- 测试构建：
  `xcodebuild build-for-testing -project ImageAll.xcodeproj -scheme ImageAll -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ImageAll-T2-3bc8e13 CODE_SIGNING_ALLOWED=NO`
  → exit 0。
- 直接 XCTest（统一使用
  `DYLD_INSERT_LIBRARIES=/tmp/ImageAll-T2-3bc8e13/Build/Products/Debug/ImageAll.app/Contents/MacOS/ImageAll.debug.dylib`）：
  - `FullLibrarySuggestionsJobTests`：66 / 66，exit 0；
  - `AppPersonalModelRebuildCoordinatorTests`：10 / 10，exit 0；
  - `AppPersonalAdamWLinearHeadTests`：4 / 4，exit 0；
  - `TrainingWorkspaceSchemaTests`：4 / 4，exit 0；
  - `CatalogMigrationTests`：12 / 12，exit 0；
  - 相关验收合计：96 / 96 通过。
- 完整直接 XCTest：1082 项；12 个既有、已标注 expected failure，
  **0 unexpected failure**。预期项来自禁签名直接测试下的 app resource /
  entitlement 检查、既有跨 migration DDL 面板与一项既有异步 UI 面板；T2
  五个相关 suite 全绿。没有启动 production App 测试宿主。
- Debug build：
  `xcodebuild build -project ImageAll.xcodeproj -scheme ImageAll -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ImageAll-T2-3bc8e13-build CODE_SIGNING_ALLOWED=NO`
  → exit 0，`** BUILD SUCCEEDED **`。
- `git diff --check`：exit 0。
- 安全审计：新增行无 `/Volumes/HDD2` 或
  `Photos Library.photoslibrary` 字面量；测试仅用 `/tmp`、临时数据库、合成图像
  与合成 embedding，未访问或枚举受保护路径。

### Codex 复审结论

- `metrics_json`：AdamW 每个实际 epoch 均落盘有限 validation loss；重启读回通过。
- 多槽：质心先发布并生成预测后再发布 AdamW，两槽、质心 artifact 指针、
  `published_run_id` 与质心预测均保留。
- 失败隔离：后续 AdamW 无效样本 Run 进入 `failed + finished_at_ms`，既有 AdamW
  与质心发布槽及质心预测不变；Feature 取消进入 `cancelled + finished_at_ms`。
- 人工事实 / 原图：相关 66 项 Review / Feature Print 回归全绿；实现不读取原图
  路径来生成 Run 元数据，不改变人工决定优先级。
- Git：实现归属为 `Codex <codex@openai.com>`、`feat(codex):`、
  `Agent-Role: implementation`；未 push、未 amend、未改写历史。

### 最终停止位置

**T2 完成，未进入 T3 / T4。** 当前已跟踪工作区在本结果文档提交后应为干净；
既存且已由 `.gitignore` 排除的 `.derivedData-*` / `.wip-*` 目录未删除、未移动、
未 stage。
