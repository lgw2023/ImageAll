# ImageAll 训练工程 T4：独立工作台

> 状态：已完成并通过 Codex 独立复审
> 日期：2026-07-23
> 权威规格：`docs/TRAINING-WORKSPACE-SPEC.md`
> 架构决策：`docs/ARCHITECTURE.md` ADR-038 / ADR-039 / ADR-040
> 上一批准基线：T3 复审留档
> `main@ae59526288f78619ee4385420d7dc8ac2f1399b8`

## 开工门

- T2 一致性修复已独立复审：91 / 91 关键测试通过。
- T3 实现提交
  `d5eb7cca4a6ab4e37d2b6bce03f636a407c15bdb`
  已通过独立复审；三轨 Review 全并行、原始 score、复合行身份和人工事实清除语义
  均已测锁。
- T3 完整直接 XCTest 为 1088 项、11 项仓库已标记 expected failures、
  0 项 unexpected failures；Debug build 成功。
- 已跟踪工作区干净；忽略目录不清理、不 stage。

T4 精确 `LAUNCH_HEAD`：
`acbebd6420d898f54607e399b7170ee62374721a`。Cursor CLI 未使用；依据
`AGENTS.md` 至 2026-08-13 的临时授权，由 Codex 直接按 TDD 实施。

## 产品契约

1. Sidebar「图库」区增加一级入口「训练工程」，中央区切换为独立整页工作台。
2. 工作台使用统一 Run 列表，按 `created_at_ms DESC, id ASC` 排序；可筛选全部、
   `featureKnn`、`personalCentroid`、`personalAdamW`，不增加「项目→Run」层级。
3. 始终展示 Feature Print、质心、AdamW 三槽状态：
   - Feature Print：至少一个 active 标签有 current revision 即已就绪；
   - 质心/AdamW：对应数据库 method 槽指向 succeeded Run 与 artifact 即已就绪。
4. 详情至少包含概览、数据、配置、过程、产物、结果六段；只展示 Run 已持久化摘要，
   不解析或展示原图路径、bookmark、受保护照片路径。
5. 工程页收拢三个发起入口：
   - Feature Print 按标签进入既有生成/更新确认流程；
   - 个人模型调用既有质心重建；
   - 超级个人调用既有 AdamW 重建。
   既有工具栏快捷入口保留。
6. Run 完成后刷新列表与三槽；筛选和选中 Run 保持稳定，选中项不再存在时回落到
   当前列表第一项。
7. 工程页按实现诚实展示门槛：Feature Print `2 确认 + 2 不属于`；质心/AdamW
   `每标签至少 2 确认`，不宣称准确率。

## 展示前审计前置

用户复审指出的两项展示语义必须在 T4 同时关闭：

1. AdamW 指标升级为 schema v1，记录 `evaluationSplit`、
   `trainSampleCount`、`validationSampleCount` 与逐 epoch `evaluationLoss`；
   无验证集时明确为 `trainFallback`，UI 不得称为验证损失。
2. 样本摘要写入真实范围与快照身份：
   - Feature Print：`scopeKind`、`requestedSourceCount`、
     `resolvedSourceCount` 与冻结任务的 snapshot revision；
   - 质心/AdamW：`scopeKind=resolvedSnapshot` 与
     `decisionSnapshotRevision`。
   不把原图路径或样本像素写入 Run。

不新增 migration；已有历史 Run 保持兼容，详情对缺失字段使用中性文案。

## TDD 纵向切片

1. RED→GREEN：训练工作台端口统一列出 Run、method 筛选和稳定时间排序，并投影三槽。
2. RED→GREEN：工作区模型进入/刷新/筛选/选择 Run，空列表和选中项失效安全回落。
3. RED→GREEN：AdamW 有验证集与小样本回退两种指标 JSON 的语义、计数和曲线。
4. RED→GREEN：Feature Print 与个人模型 Run 样本摘要包含真实范围和快照 revision。
5. 编译/视图结构验收：侧栏入口、大页六段详情、三槽状态、三个发起入口与返回图库。

## 验收矩阵

- `TrainingWorkspaceSchemaTests`：列表筛选/排序、三槽发布投影。
- `LibraryWorkspaceModelTests`：进入、刷新、筛选、选中回落。
- `AppPersonalAdamWLinearHeadTests` /
  `AppPersonalModelRebuildCoordinatorTests`：指标语义与重启落盘。
- `FullLibrarySuggestionsJobTests`：Feature Print 范围/快照审计字段。
- T2/T3 相关回归、完整直接 XCTest、Debug build。
- `git diff --check` 与受保护路径静态审计。

## 禁止事项

- 不新增或改写 v014 / v015 migration。
- 不做准确率仪表盘、图表大屏、`evaluation_assignment` 或云端训练。
- 不改变训练算法门槛，不把不同轨 score 当跨轨概率。
- 不删除历史 Run，不改变人工事实优先或三槽隔离。
- 不访问、枚举或写入 `/Volumes/HDD2` 受保护真实照片路径。
- 不启动 production App 测试宿主；只使用隔离直接 XCTest。
- 不 push、不 amend、不 squash、不清理来源不明文件。

## 停止位置

完成训练工程入口、Run 列表/筛选/详情骨架、三槽状态、发起训练收拢以及两项展示前
审计前置后，创建独立 Codex 实现 commit；随后独立复审并以单独文档 commit 回填
证据。T4 复审结束即停止，不扩展后续评测或图表能力。

## 实施结果

- 实现提交：
  `554ddc596e14bbbf817a098dd54489a8dcc07149`
  `feat(codex): add training engineering workspace`。
- Sidebar「图库」区已增加「训练工程」；中央区是独立大页，包含统一 Run 列表、
  四档方法筛选、三槽状态、概览/数据/配置/过程/产物/结果详情和三个发起入口。
- Application port 与 GRDB 投影在同一读取快照中返回按时间排序的 Run 和三槽状态；
  质心/AdamW 槽只认可数据库所指 succeeded Run，Feature Print 以 active current
  revision 为准。
- AdamW 指标使用 schema v1 的 `evaluationSplit`、样本计数与
  `evaluationLoss`；小样本明确为 `trainFallback`。历史
  `validationLoss` 在 UI 中改标为切分口径未记录，避免误称验证损失。
- Feature Print 样本摘要记录真实范围、requested/resolved source 数与冻结 payload
  SHA-256；个人模型记录与训练 artifact 相同的 decision snapshot revision。
- 详情递归过滤 path/bookmark/locator/file name 等字段，并拒绝展示绝对或 URL
  artifact 引用。

## TDD 与验证证据

- RED：首次构建因缺少 `TrainingWorkspacePort` / slot / snapshot 契约失败；
  AdamW 旧报告缺少评估口径与样本计数。
- GREEN：T4 相关
  `TrainingWorkspaceSchemaTests`、
  `AppPersonalAdamWLinearHeadTests`、
  `AppPersonalModelRebuildCoordinatorTests`、
  `FullLibrarySuggestionsJobTests`、
  `LibraryWorkspaceModelTests`
  共 241 / 241 通过，退出码 0。
- 完整直接 XCTest：1093 项，11 项仓库已标记 expected failures，
  0 项 unexpected failures；XCTest 因 expected failures 汇总退出码 1。
- `xcodebuild build-for-testing`：退出码 0，`TEST BUILD SUCCEEDED`。
- Debug build：退出码 0，`BUILD SUCCEEDED`。
- `testTrainingWorkspaceViewRendersSelectedRunDetailWithFixtureData` 使用纯 fixture
  `NSHostingView` 验证大页与选中 Run 详情可渲染；未启动 production App 宿主。
- `git diff --check` 与受保护路径静态审计：退出码 0。

## 独立复审结论

T4 产品契约与展示前审计前置均满足；未新增/改写 migration，未加入准确率、
evaluation assignment、图表或云端训练。实现、测试与工程文件归属单一实现提交，
未访问或写入受保护照片路径。T4 完成，停止在本切片边界。
