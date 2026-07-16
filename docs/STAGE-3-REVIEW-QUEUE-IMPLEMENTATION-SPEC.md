# ImageAll 阶段 3：全库个性化建议与 Review Queue 实施规格

> 状态：Approved for implementation
>
> 日期：2026-07-16
>
> 上一批准基线：`main@f8cac8906d00cbcfa4ee992b8dc5052227070ded`
>
> 权威范围：文件夹资产的全库个性化建议、持久任务与 Review Queue 纵向闭环
>
> 实施边界：不修改 v001～v004，不新增 migration，不接入 PhotoKit、FSEvents 或完整活动中心

## 1. 目标与已批准产品决策

本阶段完成以下首个端到端闭环：

```text
人工确认/否认样本
→ 用户手动启动全库建议
→ 后台可恢复地分批分析
→ 建议渐进进入 Review Queue
→ 用户批量确认、不属于或稍后
→ 新人工反馈用于下一次更新
```

项目所有者已批准：

- Sidebar 只有一个“待审核建议”入口，队列内部按标签切换，不跨标签混排；
- 用户手动生成或更新建议；一次启动遍历启动时冻结的全库范围；
- Review Queue 默认网格，`Space` 继续复用现有单图查看；
- Inspector 顺序为“预览 → AI 建议 → 人工标签 → 信息”；
- `P` 表示确认属于、`X` 表示不属于、`U` 表示稍后；
- 首版不显示百分比、原始 score 或强度等级；
- 建议渐进显示；暂停持久化，未暂停任务在下次启动继续；取消保留已发布建议；
- 不同标签可以排队，但个性化建议任务全局串行；
- 普通 Inspector 显示该资产的全部待处理建议；
- Review Queue 支持多选，`P/X` 直接执行并支持一次撤销，`U` 只移动选择。

## 2. 产品信息架构与文案

### 2.1 Sidebar 与标签概览

在“图库”区增加单一入口：

```text
全部照片
无标签
待审核建议  <建议条数>
```

徽标统计 `asset + tag` 建议条数，不是唯一照片数。进入后先显示标签概览；不得自动打开
待审核最多的标签。概览只列 active 标签，并显示：

- 标签名；
- 人工确认样本数与人工否认样本数；
- 待审核建议条数；
- 当前任务状态与已检查/总数、跳过数；
- “生成建议”“更新建议”“审核建议”“暂停”“继续”“取消”中的适用动作。

排序固定为：运行中 → 等待中 → 已暂停 → 有待审核建议 → 其余；同组先按待审核条数
降序，再按标签显示名本地化升序。

少于两个正例或两个反例时不允许生成，并显示：

```text
还需确认 N 张、标记不属于 M 张
```

首次生成和更新都先显示摘要确认，说明将检查当前所有 active 文件夹来源中已入库的照片。
更新摘要必须说明“未审核建议会在第一批新结果成功后刷新；人工标签不会改变”。

### 2.2 标签 Review Queue

- 每次只审核一个标签；标题为 `审核“<标签>”建议`；
- 网格复用现有缩略图、选择、分页和单图查看，不创建胶片带或新浏览组件；
- 排序只在当前标签内使用 `score DESC, asset_id ASC`，score 不进入 UI projection；
- Header 显示任务状态和稳定进度；冻结总数后可显示百分比；
- 生成进行时，新建议按当前排序渐进出现；
- 没有建议时区分：样本不足、等待运行、正在分析、本轮无建议、已全部审核与任务失败。

动作语义：

| 动作 | 持久化结果 | 导航行为 |
|---|---|---|
| `P` / 确认属于 | `manualAccepted` | 移除已处理建议并选择下一项 |
| `X` / 不属于 | `manualRejected` | 移除已处理建议并选择下一项 |
| `U` / 稍后 | 无数据库写入 | 主选择移动到当前选择范围之后，建议留在队列 |

`P/X/U` 只在 Review Queue 的内容焦点生效；文本输入、普通图库和其他页面不得响应。
多选时 `P/X` 原子作用于全部选中项，按钮显示影响条数，不弹确认框。成功提示例如：

```text
已确认 12 条“家人”建议 · 撤销
```

撤销恢复先前人工决定。若模型 revision 未变化，建议重新进入原有排序；若期间队列已经更新，
只保证人工决定被撤销，并提示“建议已更新，可能不再出现”。

### 2.3 Inspector

稳定顺序为：预览、AI 建议、人工标签、现有信息。信息内容本轮不扩展。

- Review Queue 只显示当前标签建议的主要动作；
- 普通图库单选时按标签名显示该资产全部 pending 建议；
- 默认展示前五条，其余通过“另外 N 条建议”展开；
- 建议行只显示标签名与“属于/不属于”按钮；
- 不显示 score、概率、强度、模型版本或伪造的解释原因；
- 普通图库中的操作不自动移动照片；
- 人工决定落库后建议行消失，人工标签区立即显示新事实。

## 3. Application 契约

新增独立 `PersonalizationReviewPort`，不得让 SwiftUI 接触 GRDB、Job、Feature 或数据库 row。
最小行为：

- 查询标签概览与 Sidebar 建议总数；
- 按标签 keyset 分页查询 Review Queue；
- 查询单资产的全部 pending 建议；
- 为标签 enqueue 全库生成/更新；
- 查询对应任务状态；
- pause、resume、cancel；
- 复用现有批量人工决定与撤销契约完成 Review 动作。

Application projection 只暴露 UI 所需字段。Review Queue cursor 可以内部携带 score 与 asset ID，
但任何展示 projection 不得公开 score。

建议任务状态至少映射为：`notReady`、`ready`、`waiting`、`running`、`paused`、
`retryableFailure`、`completed`、`terminalFailure`、`cancelled`。UI 只显示安全错误码归纳，
不显示完整路径或原始异常。

## 4. 持久 Job 与冻结范围

### 4.1 Job identity

- kind：`personalization.fullLibrarySuggestions`；
- payload version：1；checkpoint version：1；
- coalescing key：`personalization:<lowercase-tag-uuid>`；
- 每标签最多一个 active job；不同标签可以 pending；
- 个性化 worker 全局一次只 claim 一个该 kind；
- 文件夹对账 runner 只能 claim folder reconcile kind，并保持更高优先级。

Job claim 必须支持 allowed kinds，防止现有对账执行器把建议任务当成未知 kind 终止。
Composition Root 改为显式多 handler registry，不使用“未知 kind 兜底执行”。

### 4.2 Payload 与 checkpoint

只保存结构化、无路径事实：

- tag ID；
- 启动时 active folder source IDs；
- catalog cutoff timestamp；
- 固定 model revision 与样本 identity；
- last scanned asset ID keyset cursor；
- first batch 是否已发布；
- checked、eligible、suggested、skipped 计数。

启动范围是该时刻 active 文件夹来源内、cutoff 前已入库的当前 file asset。新来源、新资产、
内容 revision 改变、来源被停用或资产失效时，不把不稳定事实写入本轮建议；相关资产在安全边界
跳过，留待下一次更新。

全库按 `asset_id ASC` 小批次扫描；每批不得超过现有 500 candidate 上限。实现默认小批次应让
pause/cancel 在可接受时间内生效，不为本轮暴露用户配置。

### 4.3 原子发布与恢复

- 模型样本在任务开始时固定，运行中产生的新反馈只用于下一次更新；
- 第一批成功前继续展示旧 current revision；
- 第一批在同一个 lease-protected transaction 中创建 model revision/sample、写入首批 prediction、
  切换 current pointer、提交 checkpoint 与 Job progress；任一步失败整体回滚；
- 后续批次向同一 current revision 追加 prediction，并与 checkpoint/progress 原子提交；
- score `<= 0` 的候选不进入 Review Queue，但 cursor 仍前进，确保同一任务不重复计算；
- 未有人工决定的当前 prediction 才可显示；人工事实始终覆盖预测；
- pause/cancel 只在批次边界结算；pause 跨重启保持；未 pause 的中断任务在下次启动恢复；
- cancel 保留已发布的 current revision 与 prediction；若第一批未发布，旧队列保持不变；
- Feature Print 是可重建缓存，pause、cancel、失败和人工决定都不删除它。

现有 `FeatureVectorLoading` async API 保持兼容。实现可抽取同步核心供同步 Job handler 使用，
不得为本切片重写整个 Job 系统为 async。

## 5. 错误与并发

- 单资产 decode、source changed、不可用、授权变化等记录为 skipped 并继续其他资产；
- 持久化、checkpoint、lease 或缓存路径安全错误按现有 Job retry/terminal 规则处理；
- source 在启动后离线或停用时停止访问该来源，对其剩余资产计入跳过；
- tag 在任务期间归档时停止任务；归档标签的建议不再展示；
- WAL 读者允许在任务写入后立即刷新概览和 Review Queue；
- UI 可在运行中审核已经发布的建议；这些人工决定立即遮蔽 prediction，但不改变本次固定模型；
- 同一标签运行中不得再次 enqueue；另一个标签允许进入 pending 队列；
- App 退出不创建 LaunchAgent、XPC 或跨 App 守护进程，只在下次启动后继续。

## 6. 最小验证矩阵

遵循端到端加速原则，只保留主路径与关键失败路径：

1. 使用超过 500 个合成资产证明跨批次只发布一个 revision、cursor 不重复且建议渐进出现；
2. 注入第一批事务失败，证明 model、prediction、current pointer、checkpoint 全部回滚且旧队列不变；
3. 中断后从 checkpoint 恢复，不重复已完成 candidate；
4. pause 跨重启保持，resume 继续；cancel 保留已发布建议；
5. 两个标签任务串行，folder reconcile kind 不会 claim 建议任务且优先级更高；
6. 启动后新增/修改资产不进入冻结范围，运行中人工决定立即遮蔽建议；
7. 更新在第一批成功后替换旧 current queue，人工决定不变；
8. 概览计数、标签内分页、普通 Inspector 全部建议均正确，UI projection 不含 score；
9. 批量 `P/X` 原子、可撤销；`U` 零写入；快捷键仅在 Review Queue 内容焦点生效；
10. 相关测试、完整测试、arm64 Debug build 与 `git diff --check` 成功。

自动化测试只使用测试创建的临时合成图片，禁止访问 `/Volumes/HDD2` 或遍历 `.photoslibrary`。
如需要人工 smoke，只读使用 `/Users/liguowei/Downloads`；不得把测试能力解释为修改源照片的授权。

## 7. 停止位置

本阶段在“文件夹全库建议任务可恢复运行，建议渐进进入按标签 Review Queue，人工反馈可批量
确认/否认/撤销”处停止。继续延期：

- 强度/阈值校准与 score 文案；
- PhotoKit、iCloud 与 Photos Library；
- FSEvents、完整活动中心与资源限制设置；
- 跨 App 后台守护、相似组、自动触发更新；
- 导出、Smart Collection、比较/Survey 和高级模型。
