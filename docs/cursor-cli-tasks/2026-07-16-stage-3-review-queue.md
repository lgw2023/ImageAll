# Cursor CLI 任务：阶段 3 全库个性化建议与 Review Queue

## 任务元数据

| 字段 | 值 |
|---|---|
| 任务 ID | `stage-3-review-queue` |
| 状态 | `已完成，Codex 验收通过` |
| 日期 | 2026-07-16 |
| 上一批准基线 | `main@f8cac8906d00cbcfa4ee992b8dc5052227070ded` |
| 实际开工 HEAD | `cccd85d94e3f5adbfbf08695511c9e979b994c4f` |
| 权威规格 | `docs/STAGE-3-REVIEW-QUEUE-IMPLEMENTATION-SPEC.md` |
| Cursor session ID | `1a18f539-aad3-4003-9c01-2743c4433a78` |
| `system/init.model` | `Composer 2.5 Fast`（CLI 显式请求 `composer-2.5-fast`） |
| 交付 commit | `45c86b9`、`a9a6c51`、`2466913`、`d76ebdf` |
| Codex 评审 | `main@d76ebdf` 通过 |

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

## 实施结果

- 实际开工 HEAD：`cccd85d94e3f5adbfbf08695511c9e979b994c4f`；分支 `main`；
- `system/init.model`：`Composer 2.5 Fast`，符合 CLI 的 `--model composer-2.5-fast`；
- Cursor session ID：`1a18f539-aad3-4003-9c01-2743c4433a78`；初次实施使用全新 session，
  三次未通过验收的窄范围返修均按规则续接同一 session；
- Cursor 实现提交：
  - `45c86b97308b65d0cc260af79ef1bcb32a323716` — 初次端到端实现；
  - `a9a6c51452ef24233f17660bae06f645144dcf56` — 冻结事实、pause/cancel、错误分类、
    渐进 runner、同步 Feature Print 与产品行为返修；
  - `2466913c03de032239d88ee12bcf358579cc7783` — 调度优先级、运行中刷新、
    已提交 checkpoint 恢复与变化资产 skipped 返修；
  - `d76ebdfaf6381249769323528eb89803883b4273` — `U`/`P/X` 选择、opaque cursor 与
    Inspector 旧建议返修；
- 独立测试：`xcodebuild test -scheme ImageAll -destination 'platform=macOS'` 退出码 0；
  `/tmp/ImageAll-Stage3-Codex-20260716.xcresult` 为 **725 passed / 0 failed / 0 skipped**；
- 独立 Debug build：`xcodebuild build -scheme ImageAll -configuration Debug
  -destination 'platform=macOS' -quiet` 退出码 0；
- `git diff --check`：无问题；
- 作者/trailer：四个实现提交均为 `Cursor Agent <cursoragent@cursor.com>`，主题分别使用
  `feat(cursor):`/`fix(cursor):`，并带 `Agent-Role: implementation`；
- Codex 评审结论：`main@d76ebdf` 通过阶段 3 验收；冻结范围、首批原子发布、恢复/暂停/取消、
  folder 优先、串行 runner、渐进可见、Review Queue、普通 Inspector 建议、批量决定/撤销与
  score 隔离均满足本交接单；
- Cursor 最终工作区：仅本记录的 Codex 未提交修改与既有未跟踪 `user/`；实现文件已提交；
- 数据安全：自动测试仅使用临时合成 fixture，未访问 `/Volumes/HDD2`；`user/` 未读取、修改或暂存；
- Push：否。

## 同一交接单窄范围返修 1（已完成）

初次实施会话在运行新增 Job 集成测试时出现约 60 秒后测试宿主退出、用例耗时显示
`0.000 seconds` 的症状。Codex 独立检查发现首批和后续批次的 lease-protected
transaction 内部再次调用了会自行执行 `DatabasePool.write` 的 Catalog Repository 方法。
这既可能造成 GRDB 写连接重入/等待，也不满足「模型 revision、prediction、current revision、
checkpoint 同一事务」的核心契约。

返修必须继续同一 Cursor session `1a18f539-aad3-4003-9c01-2743c4433a78`，禁止新建会话，
并先完成以下阻塞修正后再追踪测试症状：

1. 为模型发布、替换 prediction、追加 prediction 提供接收当前 `Database` 的事务内实现；
   对外便捷 API 可以继续包装 `pool.write`，但 Job handler 必须使用
   `commitLeaseProtectedBatch` 闭包传入的同一个 `Database`，闭包内部不得嵌套
   `DatabasePool.write`。
2. 第一批的 frozen samples、model revision、prediction、current revision 与 checkpoint
   必须在同一 lease-protected transaction 原子提交；注入失败时旧 current revision 和旧队列不变。
3. 修正测试 fixture 的已决定资产/旧 prediction 冲突，并给需要 lease context 的 coordinator
   补齐同一 `GRDBJobQueue` provider；不得通过删减验收测试、放宽断言或延长超时掩盖问题。
4. 在最终 UI 复核中把 Inspector 顺序修正为“预览 → AI 建议 → 人工标签 → 信息”，并修正
   Review Queue 批量 `P/X` 后自动选择下一项的状态更新。
5. 完成相关测试、完整测试、Debug build 与 `git diff --check` 后，才允许创建 Cursor 实现提交。

## Codex 独立复审 1（未通过，已返修）

复审对象：`45c86b97308b65d0cc260af79ef1bcb32a323716`。事务内嵌套
`DatabasePool.write` 已修正，708 项测试和 Debug build 证据有效；但以下仍为阻塞项，必须继续
同一 Cursor session 返修，使用新的 `fix(cursor):` commit，不 amend `45c86b9`：

1. **冻结事实不完整。** payload/checkpoint 未固定 model revision 与带 content revision 的样本
   identity；handler 开始时重新读取人工样本，可能把 enqueue 后的新反馈带入本轮。候选查询只用
   `record_created_at_ms` 且继续依赖当前 source/locator 状态，导致启动后修改的现有资产可能被本轮
   重新评分，source 停用/资产失效则从范围中静默消失而非计入 skipped。需按 cutoff 与
   `updated_at_ms`/`record_updated_at_ms` 固定启动事实，并增加“enqueue 后反馈”“内容修改”与
   “source 停用”测试。
2. **pause/cancel 安全边界错误。** handler 丢弃 `commitLeaseProtectedBatch` 返回 snapshot；如果
   control request 在批次处理中到达，该 commit 已把 Job 结算为 paused/cancelled，但 handler 仍
   继续循环并使用失效 lease。每次批次提交后必须检查 snapshot，非 running 立即停止；测试必须在
   第一批发布后触发 pause/cancel，证明持久暂停、新 coordinator 恢复、取消保留部分结果。
3. **错误分类错误。** 单资产 `catch` 吞掉 `cacheUnsafePath`/`cachePersistenceFailed`，外层又把
   持久化等错误全部记成 non-retryable 且返回空 checkpoint/progress。仅资产不存在、失效、授权/
   source changed、decode/generation 可计 skipped；缓存路径与持久化/数据库错误必须走现有
   retryable→terminal 规则，并保留最近已提交 checkpoint/progress。增加故障注入测试。
4. **端到端渐进 UI 未成立。** `enqueueSuggestions` 和启动 reload 都等待
   `runPendingPersonalizationJobs()` 排空才刷新，运行中看不到进度/新增建议，也无法获得 pause/cancel
   控件。实现单一串行后台 runner：enqueue 后立即刷新 waiting 状态并返回，后台处理期间周期刷新
   概览/当前队列；同一 App 内不能启动第二个个性化 worker；启动先完成 folder runner 再启动建议
   runner。不得用多个 detached runner 破坏全局串行。
5. **Feature Print 同步边界不合格。** 删除 semaphore `AsyncFeatureVectorBridge`；把现有
   `FeaturePrintCacheService` 的实际同步核心暴露给后台 handler，async Application API 仅包装/复用
   同一核心，避免阻塞 Swift concurrency executor。
6. **产品行为缺口。** 生成/更新前必须显示摘要确认；是否显示“更新建议”应以 current model 是否
   已存在判断，而不是 pending 数量（队列全审完仍应是更新）；样本不足提示只在确实缺样本时显示。
7. **验收测试缺口。** 补齐：首批后渐进可见、更新替换旧 current queue 且人工事实不变、运行中
   修改/新增资产排除、固定样本、批量 P/X 原子与一次 Undo、U 零数据库写入、快捷键仅 Review 内容
   焦点路由。不得用弱化断言或仅测试 fixture 自身代替产品行为。

仍须保持：不修改 v001-v004、不新增 v005、不访问 `/Volumes/HDD2` 或 `user/`、不 push。

## Codex 独立复审 2（未通过，已返修）

复审对象：`a9a6c51452ef24233f17660bae06f645144dcf56`。720 项测试与 Debug build
已经通过，但以下测试与实现没有满足阶段 3 的原子性和端到端行为，必须继续同一 Cursor session
`1a18f539-aad3-4003-9c01-2743c4433a78`，创建新的窄范围 `fix(cursor):` commit，禁止
amend `a9a6c51`：

1. **启动后修改被静默排除而非计为 skipped。** `frozenAssetBatch`/`frozenAssetTotal` 同时过滤
   `a.record_updated_at_ms <= catalogCutoffMs`，所以启动时已存在、之后被修改的资产不会进入批次；
   `testContentModifiedAfterCutoffIsExcludedFromScan` 只断言无 suggestion，没有断言 checked/skipped。
   冻结范围应以启动时已存在的资产为基线（至少 `record_created_at_ms <= cutoff` 和冻结 source IDs），
   然后在 processing context 使用 asset/source 的更新时间、locator/current、availability、content revision
   判断启动后变化并计 skipped。修改测试名称与断言，明确该资产使 checked 与 skipped 增加且不产生 prediction；
   新增资产仍不得进入 total/批次。
2. **渐进 UI runner 实际只在整标签结束后刷新。** `runOneStep` 等待
   `runPendingSuggestionJobs(maxSteps: 1)` 返回，而一次 coordinator handler 会循环处理完整标签；300ms
   sleep/refresh 位于返回之后，长任务期间没有任何 UI refresh。保留单 worker 串行语义，但在 worker
   执行期间用独立 ticker 周期调用 MainActor refresh，并在 worker 完成后停止该 ticker；不得并行启动第二个
   personalization claim。增加可控阻塞 fake/runner 测试，证明 worker 尚未返回时已发生至少一次 refresh，
   且同时最多一次 `runPendingSuggestionJobs`。
3. **retryable checkpoint 越过未提交批次。** `retryableFailureWithPartialBatch` 把当前批次的
   `lastCheckedAssetID` 与计数写入 checkpoint，但该批次 predictions 尚未进入 lease-protected transaction；
   恢复后 keyset cursor 会跳过这些未落库候选，造成结果丢失。缓存/数据库失败只能保留“最近一次已原子提交”
   的 `state`；首批前失败写编码后的 empty checkpoint，后续批次失败保留上一批 checkpoint，绝不能推进
   未提交批次 cursor/progress。增加故障注入测试：第一批成功、第二批中途失败、恢复后完整扫描，最终 prediction
   与无故障基线一致且无遗漏/重复。
4. **文件夹任务优先级尚未在真实调度中成立。** personalization claim 使用 allowedKinds 只看建议任务，
   folder runner 又是另一条执行路径；两个 worker 可并发，Job priority `0 > -1` 不会跨这两个 claim 生效。
   在不引入活动中心/守护进程的前提下，用最小机制保证有 pending/running/retryable folder reconcile 时不开始
   新的 personalization claim；已经进入安全批次的任务无需中途抢占。增加服务/调度测试：folder 与 suggestion
   同时等待时，先处理 folder，之后才领取 suggestion。

保持已经修复的冻结样本 identity、pause/cancel snapshot、确认 UI、current model 更新语义、同步
Feature Print 核心、P/X/U 行为和 UI 顺序不回退。完成后再次运行相关测试、完整测试、Debug build 与
`git diff --check`；只暂存实现/测试，排除本记录和 `user/`，不 push。

## Codex 独立复审 3（未通过，已返修并通过最终验收）

复审对象：`2466913c03de032239d88ee12bcf358579cc7783`。第二轮四项调度/冻结/checkpoint
修正已经通过相应测试，723 项完整测试与 Debug build 证据有效；但最终产品交互复核发现以下三项
仍直接违反已批准契约。必须继续同一 Cursor session
`1a18f539-aad3-4003-9c01-2743c4433a78`，创建新的窄范围 `fix(cursor):` commit，禁止 amend：

1. **`U` 改变了本地队列顺序。** `deferReviewSelection()` 当前把所选项移动到
   `reviewQueueItems` 尾部，而批准语义是“只移动选择到下一项，不写数据库、不改变队列”。保持
   `reviewQueueItems` 的顺序与内容完全不变；选择移动到最后一个选中项之后的首个未选项，末尾时可循环到
   队首的首个未选项；全部项目都被选中时保持稳定。重写现有测试，先保存原始 asset ID 顺序，执行 `U`
   后断言顺序完全相等、数据库 mutation 次数为 0、选择已前进。批量 `P/X` 也应按原队列位置选择真正的
   下一项，而不是无条件跳到队首；补一个从队列中部处理单项的回归测试。
2. **原始 score 进入了 UI-facing cursor。** `ReviewQueueCursor` 目前公开 `score: Double`，而
   `PersonalizationReviewPort` 和 `LibraryWorkspaceModel` 直接携带它，违反“score 不进入任何 UI
   projection”。把分页边界改成不暴露 score 的 opaque cursor/token；score 只能在 Infrastructure 内部
   编码/解码并用于 SQL keyset，SwiftUI/Application 不得可访问原始数值或 score 命名字段。现有分页仍须
   稳定；测试同时反射 `ReviewQueueItemProjection` 与 `ReviewQueueCursor`，确认均无 `score` 字段，并
   实际获取第二页证明无重复/遗漏。
3. **普通 Inspector 会残留上一张照片的 AI 建议。** `refreshInspector()` 在从单选切到多选及错误路径
   没有清空 `assetPendingSuggestions`，因此可能显示并操作旧资产建议。非恰好单选时、选择为空时和加载失败
   时都必须清空建议；切换单选资产后展开状态还应恢复为默认前 5 条。增加 model 测试：先单选得到建议，
   再进入多选，断言 suggestions 为空且没有旧行内操作目标。

不得弱化已有 723 项行为断言；不得修改 migration、entitlement、依赖或本任务外文件。完成相关测试、
完整测试、Debug build 与 `git diff --check` 后，仅提交实现/测试文件，排除本记录与 `user/`，不 push。
