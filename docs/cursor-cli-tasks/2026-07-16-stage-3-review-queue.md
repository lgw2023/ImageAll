# Cursor CLI 任务：阶段 3 全库个性化建议与 Review Queue

## 任务元数据

| 字段 | 值 |
|---|---|
| 任务 ID | `stage-3-review-queue` |
| 状态 | `待执行` |
| 日期 | 2026-07-16 |
| 上一批准基线 | `main@f8cac8906d00cbcfa4ee992b8dc5052227070ded` |
| 实际开工 HEAD | `<LAUNCH_HEAD>` |
| 权威规格 | `docs/STAGE-3-REVIEW-QUEUE-IMPLEMENTATION-SPEC.md` |
| Cursor session ID | 待补 |
| `system/init.model` | 待补，必须为 `composer-2.5-fast` / `Composer 2.5 Fast` |
| 交付 commit | 待补 |
| Codex 评审 | 待补 |

## 完整 CLI 命令模板

调用时由 Codex 把本文中的 `<LAUNCH_HEAD>` 替换为包含本任务记录的实际文档提交 SHA；启动
全新 session，不使用 `--resume`：

```bash
agent -p --model composer-2.5-fast --force --sandbox disabled --trust \
  --output-format stream-json --workspace /Volumes/SSD1/ImageAll \
  '<下方“完整任务正文”，其中 <LAUNCH_HEAD> 替换为实际 SHA>'
```

## 完整任务正文

你是 ImageAll 本任务唯一实现开发者。必须使用当前全新 Cursor CLI session，不得恢复旧会话，
不得调用 Cursor 子代理或 MCP。开始前完整阅读：

1. `/Volumes/SSD1/ImageAll/AGENTS.md`；
2. `/Volumes/SSD1/ImageAll/.cursor/rules/codex-review-handoff.mdc`；
3. `/Volumes/SSD1/ImageAll/docs/STAGE-3-REVIEW-QUEUE-IMPLEMENTATION-SPEC.md`；
4. `/Volumes/SSD1/ImageAll/docs/STAGE-3-BACKEND-IMPLEMENTATION-SPEC.md`；
5. `/Volumes/SSD1/ImageAll/docs/STAGE-1-PRODUCT-UI-SPEC.md`；
6. `/Volumes/SSD1/ImageAll/docs/LOCAL-TEST-DATA-SAFETY.md`。

### 开工基线与上一门结论

- 精确开工 HEAD：`<LAUNCH_HEAD>`；分支必须为本地 `main`；
- 上一门已通过：阶段 3 backend prototype 已在 `f8cac89` 记录，v004、Feature Print 和显式
  candidate scoring 可用，最终证据为 700 tests passed 与 Debug build succeeded；
- 开工工作区预期只有既有未跟踪 `user/`；它属于用户，不得读取、修改、暂存或提交；
- 若 HEAD、分支或工作区与以上不符，立即停止并报告，不得 reset、checkout、stash、clean 或覆盖。

### 当前任务

完整实施权威规格定义的端到端纵切片：

1. 新增独立 Application `PersonalizationReviewPort` 与无 GRDB/Job/score 泄漏的 UI projections；
2. 新增 `personalization.fullLibrarySuggestions` 持久 Job、payload/checkpoint 严格验证、按 kind claim
   和多 handler registry；每标签 coalescing、不同标签全局串行、folder reconcile 优先；
3. 启动时冻结 active folder source IDs 与 catalog cutoff，按 asset ID keyset 小批次遍历全库；
4. 固定模型样本，第一批用 lease-protected transaction 原子发布 model/sample/prediction/current
   pointer/checkpoint，后续批次向同一 revision 渐进追加；
5. 支持中断恢复、持久 pause/resume、cancel 保留已发布建议；第一批前失败或取消保留旧队列；
6. 在 Composition Root 接入 worker 与 review service，App 启动后恢复未暂停建议任务；
7. Sidebar 增加单一“待审核建议”入口与条数，入口先显示标签概览；
8. 实现按标签网格 Review Queue、普通 Inspector 全部建议、Inspector 顺序调整；
9. 实现多选 `P/X`、`U` 零写入移动、自动前进和一次 Undo；快捷键只在 Review Queue 内容焦点有效；
10. 首版 UI 不显示 score、概率、强度或模型版本。

请采用最小、直接实现，不添加本任务外抽象。允许按内部 tracer-bullet 顺序完成后端 Job、查询端口、
UI 接入与测试，但最终作为一个窄范围 Cursor 实现 commit 交付。

### 强制契约

- 不修改 v001～v004，不新增 v005 或其他 migration；
- 不修改 entitlement、PrivacyInfo、Swift Package 依赖、deployment target 或签名策略；
- 保持现有 `FeatureVectorLoading` async API；可抽同步核心供 Job handler 复用，不把整个 Job 系统
  改写为 async；
- 第一批发布与 Job checkpoint 必须处于同一 lease-protected transaction；
- 旧 queue 到第一批成功前保持可见；第一批成功后 new revision 成为 current；
- score 仅用于同标签 SQL 排序/cursor，绝不进入任何展示 projection 或 SwiftUI 文案；
- 人工 accepted/rejected 始终高于 prediction；`U` 不产生数据库写入；
- 运行中单资产错误可跳过，数据库/lease/checkpoint/cache path 安全错误按 Job 状态机结算；
- 个性化任务不得阻塞或误领取 folder reconcile；不同标签建议任务不并行；
- 不读取或写入 `/Volumes/HDD2`，不遍历任何 `.photoslibrary`；自动测试只用临时 fixture；
- 不删除、移动、重命名、覆盖或写 sidecar/元数据到任何源照片；
- 不 push、不 amend、不改写历史，不触碰任务外文件。

### 验收矩阵

最少覆盖：

1. `>500` 个合成资产跨批次、同一 revision、无重复 cursor、渐进建议；
2. 第一批事务注入失败全部回滚且旧 queue 不变；
3. 中断恢复、pause 跨重启、resume、cancel 保留已发布建议；
4. 两个标签串行；folder runner 只 claim 自己的 kind 且优先；
5. 冻结范围排除运行后新增/变化资产；人工决定立即遮蔽 suggestion；
6. 更新第一批成功后替换旧 current queue，人工事实不变；
7. 标签概览、标签内 keyset page、普通 Inspector 全部建议正确，UI projection 不含 score；
8. 批量 `P/X` 原子并可 Undo；`U` 零写入；快捷键焦点边界；
9. 现有目录浏览、人工标签、搜索、缩略图与 backend personalization 主路径无回归。

运行相关测试、完整：

```bash
xcodebuild test -scheme ImageAll -destination 'platform=macOS'
xcodebuild build -scheme ImageAll -configuration Debug -destination 'platform=macOS'
git diff --check
```

测试总数必须从实际输出计算，不得沿用旧数字。

### Git 交付

只暂存本任务实现、测试与必要 Xcode 工程引用，明确排除 `user/` 与 Codex 文档。使用：

```bash
git -c user.name='Cursor Agent' -c user.email='cursoragent@cursor.com' commit \
  -m 'feat(cursor): add full-library suggestion review workflow' \
  -m 'Agent-Role: implementation'
```

提交后验证：

```bash
git show -s --format='%an <%ae>%n%s%n%(trailers)' HEAD
git status --short --branch
```

最终输出必须按 `.cursor/rules/codex-review-handoff.mdc` 给出完整中文「Codex 复审材料」，包括
实际模型、session ID、开工/交付 SHA、逐文件职责、测试命令与实际总数、build、作者 trailer、
工作区状态、明确未做项以及 3～5 个重点审查点。

### 停止位置

提交上述单一实现 commit 后停止，等待 Codex 复审。不得进入强度校准、PhotoKit、FSEvents、
完整活动中心、跨 App 守护、相似组、自动触发、导出、Smart Collection、Compare 或 Survey。

## 禁止事项与数据安全

- 不访问 `/Volumes/HDD2/Photos Library.photoslibrary` 或 `/Volumes/HDD2` 年份目录；
- 不读取、修改、暂存或提交 `user/`；
- 不 push、不改写 Git 历史、不修改既有 migration；
- 不使用 `auto` 或其他模型，不恢复旧 Cursor session；
- 不把完整 `stream-json`、凭据、照片内容或用户路径详情写入仓库。

## 实施结果（Cursor 交付后由 Codex 补记）

- 实际开工 HEAD：待补
- `system/init.model`：待补
- Cursor session ID：待补
- 交付 commit：待补
- 测试：待补
- Debug build：待补
- 作者/trailer：待补
- Codex 评审结论：待补
- 最终工作区：待补
- Push：否
