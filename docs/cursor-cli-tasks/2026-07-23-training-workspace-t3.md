# ImageAll 训练工程 T3：Review 全并行

> 状态：Codex 直接实施中  
> 日期：2026-07-23  
> 权威规格：`docs/TRAINING-WORKSPACE-SPEC.md`、`docs/SUGGESTION-THRESHOLD-SPEC.md`  
> 架构决策：`docs/ARCHITECTURE.md` ADR-038 / ADR-039 / ADR-040  
> 上一批准基线：`main@4987882e537f0e68a7e38afbbf9392c82ef62e52`

## 开工门

- 复审 T2 实现提交 `fa9715aa6e74490a8777c6f8e8d0e5e57acb281d`
  与留档提交 `4987882e537f0e68a7e38afbbf9392c82ef62e52`。
- `main` 与 `origin/main` 一致，已跟踪工作区干净；忽略目录不清理、不 stage。
- 独立 `build-for-testing` 通过；T2 关键套件
  `FullLibrarySuggestionsJobTests`、
  `AppPersonalModelRebuildCoordinatorTests`、
  `AppPersonalLinearHeadStoreTests`、
  `TrainingWorkspaceSchemaTests` 共 91 / 91 通过。
- 结论：T2 两项阻塞一致性问题已经关闭，可以进入 T3。

本文档初始提交为 T3 `LAUNCH_HEAD`；实施结果回填时记录精确 commit。
Cursor CLI 未使用；依据 `AGENTS.md` 至 2026-08-13 的临时授权，由 Codex
直接按 TDD 实施。

## 产品契约

1. 同一 `asset_id + tag_id` 的 Feature Print、质心与 AdamW pending 建议
   同时投影，不再按资产折成一行。
2. 队列行稳定身份包含 `asset_id + suggestion_origin`；当前队列已由 `tag_id`
   约束，因此该身份完整表达 `(asset, tag, origin)`。
3. 排序固定为 `personalAdamW` → `personalModel` → `featurePrint`；
   `standardModel` 保持既有标准轨，并置于三条个人相关轨之后。轨内按
   `score DESC, asset_id ASC`。
4. 每行显示 origin 徽章和原始 score；分数仅在同轨内解释，不作跨轨概率比较。
5. 确认或拒绝任一行仍只写一条人工事实；该事实使同一
   `asset_id + tag_id` 下所有 origin pending 从投影消失。
6. 「稍后」不写库、不删除任何 origin 行，并能移动到下一条稳定队列行。
7. 待审核徽标、标签概览和 Inspector 都按 `(asset, tag, origin)` 计数/展示；
   Inspector 同标签多 origin 不得折叠。

## TDD 纵向切片

1. RED→GREEN：三轨重叠时队列返回三行、三个稳定 ID、固定 origin 顺序和原始 score。
2. RED→GREEN：确认任一 origin 后三轨全消失且人工决定正确；撤销后按既有 revision
   规则重新出现。
3. RED→GREEN：总数与标签概览按 origin 行计数。
4. RED→GREEN：Inspector 对同一标签返回三条带不同 origin 的建议。
5. RED→GREEN：工作区选择/稍后逻辑使用队列行身份，不因同资产多 origin 跳过或
   产生重复 `ForEach` 身份。

## 验收矩阵

- `FullLibrarySuggestionsJobTests`：三轨并行、排序、计数、人工事实级联清除、
  Inspector 多 origin。
- `LibraryWorkspaceModelTests`：行身份、选择、稍后、删除后下一项选择。
- `SuggestionThresholdTests`：原始 score 仍展示且阈值行为不回归。
- 完整非宿主 XCTest：0 unexpected failure。
- Debug build：成功。
- `git diff --check`：成功。

## 禁止事项

- 不修改 v014 / v015，不新增 migration。
- 不进入 T4，不增加训练工程侧栏或大页。
- 不改变三种训练算法、训练门槛或 Run 生命周期。
- 不把三轨 score 当作可跨轨比较的概率。
- 不访问、枚举或写入 `/Volumes/HDD2` 受保护真实照片路径。
- 不启动 production App 测试宿主；只使用隔离直接 XCTest。
- 不 push、不 amend、不 squash、不清理来源不明文件。

## 停止位置

T3 相关测试、完整非宿主回归、Debug build、Git 与照片安全审计通过后，
创建独立 Codex 实现 commit，再以独立文档 commit 回填证据。完成 T3 复审后，
才创建新的 T4 留档并进入训练工程大页。

