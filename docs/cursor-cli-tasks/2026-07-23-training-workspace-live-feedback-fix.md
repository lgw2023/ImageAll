# 训练工程实时反馈修复

> 状态：已完成并通过 Codex 独立复审
> 日期：2026-07-23
> 权威规格：`docs/TRAINING-WORKSPACE-SPEC.md`
> 开工基线：`main@dd09a70a15aa8a94c537d60e8d0a3fb10bf824ae`
> 实现提交：`2011469252dea0f041fd3d4c75d995c3385d6275`

## 现场问题

用户在训练工程中对“板栗”与所有来源发起个人模型（质心）训练后观察到：

1. 页面刷新按钮持续在普通图标与进度环之间频闪；
2. 样本准备期间尚未建立 `training_run`，工作台仍显示空记录，无法确认动作是否已开始；
3. 页面与 Inspector 未展示方法、标签、范围、样本数或当前阶段。

根因审计：

- 建议后台 runner 每 300 ms 刷新 Review 与训练工作台；
- 所有刷新共用 `isRefreshingTrainingWorkspace`，后台轮询也会切换手动刷新按钮；
- 个人模型路径在调用 runtime 前先逐样本准备 embedding，Run 要到 runtime 接手后才创建，
  期间只有内部布尔状态且页面没有对应展示。

## 修复契约与停止位置

1. 只有用户点击“刷新”才显示刷新按钮进度；进入页面、筛选变化、后台 runner、训练轮询与
   完成刷新都使用静默刷新。
2. 质心与 AdamW 从读取训练样本开始发布页面级活动状态，展示：
   - 方法；
   - 训练标签；
   - 所有来源或当前所选照片范围；
   - 解析后的样本数；
   - 读取样本、准备本地特征、训练并发布三个阶段。
3. embedding 准备展示完成数与总数；Run 创建后每 500 ms 静默刷新列表与三槽，
   训练结束后停止轮询并执行最终刷新。
4. 状态条、三槽、空列表提示与 Inspector 使用同一活动事实；失败仍沿用既有安全通知，
   不改训练算法、Run 数据契约、Review 并行语义或 migration。
5. 停止在训练工程实时反馈修复，不扩展准确率、评测、图表或云端训练。

## TDD 证据

逐条 RED→GREEN：

1. `testTrainingWorkspaceAutomaticRefreshDoesNotAnimateManualRefreshControl`
   - RED：`refreshTrainingWorkspace` 不区分自动与用户刷新；
   - GREEN：新增显式刷新来源，自动刷新期间手动按钮状态保持不变。
2. `testPersonalCentroidTrainingPublishesLiveWorkspaceActivityUntilCompletion`
   - RED：模型没有可观察的训练工程活动；
   - GREEN：阻塞式质心训练期间可读取完整活动事实，结束后清理。
3. `testTrainingWorkspaceActivityPresentationExplainsMethodTagsScopeAndProgress`
   - RED：没有用户可见的活动文案投影；
   - GREEN：稳定展示“板栗 / 所有来源 / 2 张 / 本地特征 1 / 2”等信息。

## 验证结果

- `LibraryWorkspaceModelTests`：全套通过，退出码 0。
- 完整直接 XCTest：1101 项，11 项仓库既有 expected failures，0 项 unexpected
  failures；XCTest 汇总退出码 1。
- `xcodebuild build-for-testing`：退出码 0。
- Debug build：退出码 0。
- `git diff --check`：退出码 0。
- 构建仅有既有 LibRaw 目标版本 linker warnings。

测试与实现均使用程序生成 fixture；未访问、枚举或写入 `/Volumes/HDD2` 受保护真实照片
路径。未新增或改写 migration，未 push、amend、squash 或改写历史。

## 变更职责

- `ImageAll/App/LibraryWorkspace.swift`
  - 区分用户/自动刷新；
  - 发布个人模型训练活动与 embedding 进度；
  - 训练期间静默轮询 Run。
- `ImageAll/App/TrainingWorkspaceUI.swift`
  - 增加活动状态条、三槽训练状态、空列表进行中提示与 Inspector 反馈。
- `ImageAllTests/LibraryWorkspaceModelTests.swift`
  - 测锁刷新稳定性、活动生命周期和可见文案。

## 复审结论

刷新按钮频闪与个人模型预处理阶段无反馈均已关闭。自动刷新仍持续更新 Run，不再伪装成
用户手动刷新；训练事实不包含原图路径、bookmark 或受保护 locator。修复未越过 T4
工作台边界。
