# 训练工程工作区 T2

## 任务状态

- 状态：Codex 直接实施中（2026-08-13 前临时实施授权）
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

## 执行结果（待补记）

- `LAUNCH_HEAD`：待文档提交后填写
- 实现 commit：待填写
- 测试 / 构建证据：待填写
- Codex 复审结论：待填写
- 最终工作区：待填写
