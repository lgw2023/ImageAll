# ImageAll 阶段 1 加速交付计划

> 状态：Slice A-B implemented；Slice B pending owner UX review  
> 日期：2026-07-15  
> 设计基线：`main@a03d1296b4f7ffa22de369baebc89042ea94283f`
> Slice A 实现：`main@0e7dd655f99a57730025355fde6bacdff564e0f4`  
> Slice B 实现：`main@542c76b97a06b1ec9ea31418fadaa9e355ae7b03`

## 1. 决策

阶段 1 后半程从“先补齐后端辅助能力”改为“先形成可运行用户纵切片”。已经通过的切片 1～4 保持不变；原切片 5 的 FSEvents、完整活动投影和任务控制不再阻塞首个可用 App。

当前最短主路径固定为：

```text
启动并打开目录库
→ 用户点击“连接照片文件夹…”
→ 系统只读目录选择
→ 执行首次 reconcile Job
→ 已入库照片进入分页网格
→ 按需生成并显示 gridRegular 缩略图
→ 用户可手动刷新来源
→ 选择照片并在 Inspector 作出人工标签决定
→ 用本地搜索、来源、标签决定和无标签条件缩小结果
```

## 2. 加速切片 A：连接、扫描、浏览

本切片只实现：

- 空库只读说明与“连接照片文件夹…”入口；
- 连接成功后执行已有 `folder.reconcile.v1` Job，结束后刷新目录查询；
- 全部照片的 `newest` 分页网格，首版每页最多 100 项；
- 网格按需请求已有 `gridRegular` 派生图；
- 来源级“立即重扫”按钮；
- 启动中、扫描中、空库、错误和有内容五种最小可观察状态；
- 只记录安全错误摘要，不在界面或日志显示 bookmark、绝对路径或逐文件清单。

首版不要求扫描过程中逐批刷新 UI；一次 reconcile 完成后展示结果即可。该体验缺口记录为技术债，避免为实时投影引入额外调度层。

## 3. 加速切片 B：Inspector 人工标签与基础搜索筛选

本切片实现：

- 三栏 `NavigationSplitView`，右栏 Inspector 在没有选择时显示明确空状态；
- 单击、`Command` 多选和 `Shift` 范围选择，筛选后不可见选择明确清除；
- 单选 Inspector 使用 `preview` 派生图并显示文件名、来源、相对位置、格式、尺寸、大小和可用状态；
- 单选/多选的人工标签 `accepted`、`rejected`、`unknown` 与 mixed 聚合；
- 对全部所选资产执行确认、拒绝、清除决定；清除不等于拒绝；
- 在 Inspector 内创建标签并原子确认应用到当前选择；
- 一次成功标签事务的 Undo；失败事务不进入或覆盖 Undo 历史；
- 本地搜索提交，复用既有文件名、相对路径、标签名和来源名搜索语义；
- 来源、无标签、具体标签的已确认/已拒绝筛选，以及多标签明确 ALL/ANY；
- 网格的人工作出决定数量提示和安全的非模态失败摘要。

本切片不新增 schema、entitlement、privacy manifest 或依赖；SwiftUI 只消费 Application 层工作区状态，GRDB 仍限定在 Infrastructure。

## 4. 明确延期

Slice B 完成后仍明确延期：

- FSEvents watcher、dirty trigger 与自动增量重扫；
- Activity 工作区、任务列表、暂停、取消、重试；
- `Command-K`、Space 单图查看、方向键移动主选择和多窗口状态同步；
- 可用状态、文件格式筛选与排序切换界面；
- Inspector 技术错误详情、标签操作前的独立影响数量确认；
- 10,000/100,000 项性能基准、完整无障碍矩阵和所有故障注入；
- 真实 `/Volumes/HDD2` 数据 smoke。

这些项目进入阶段 1 技术债清单，后续按对实际使用价值的影响排序补回。延期不包括来源只读、bookmark 生命周期、目录边界、原子数据库写入、派生缓存路径安全和真实照片保护。

## 5. 最小验证门

为了加快交付，本切片只要求：

1. 一个公开界面级模型测试证明“空库可连接，成功后执行扫描并出现照片”；
2. 一个失败测试证明连接/扫描失败进入安全错误状态且不会伪装为空库；
3. 相关既有授权、对账、查询和派生图测试保持通过；
4. arm64 Debug build 成功；
5. entitlement、privacy manifest 和 `/Volumes/HDD2` 零访问边界不变。

不再为本切片新增重复 schema introspection、全量 fault matrix 或实现细节测试。若最小回归发现既有缺陷，只修复阻塞主路径的问题，其余记录后置。

## 6. 停止位置

切片 B 停止于“浏览—选择—人工标签—搜索筛选”闭环。FSEvents、活动中心和扩展验证继续延期；下一纵切片应先根据项目所有者对当前三栏工作台的实际体验反馈，在单图查看/键盘浏览、来源生命周期界面或其他直接用户主路径中择一，不默认回补 watcher/活动能力。

## 7. 切片 A 验收记录

2026-07-15 已完成并通过：

- 启动 gate 成功后由 Composition Root 组装授权、reconcile Job、目录查询和派生图缓存；
- 空库只读说明、用户触发的系统目录选择、来源侧栏、手动重扫、分页方形网格和按需 `gridRegular` 缩略图已接入；
- TDD 红灯证据：`/tmp/ImageAll-accelerated-red.xcresult`；目标模型测试 2/2 通过；
- 相关授权、对账、查询、派生图与 Composition Root 回归 62/62 通过：`/tmp/ImageAll-accelerated-related.xcresult`；
- arm64 Debug build 成功；entitlement 与 privacy manifest 未改；
- 自动化未访问 `/Volumes/HDD2`，未运行真实 App 容器 smoke，未 push。

已知延期：扫描完成后才整体刷新网格；没有 FSEvents、活动中心、单图查看或真实数据 smoke。这些缺口不阻塞切片 A 的“连接—扫描—浏览”闭环。

## 8. 切片 B 验收记录

2026-07-15 已完成本地实现与验证，等待项目所有者实际 UX 评审：

- Inspector 单选/多选标签三态、mixed、创建并确认、一次 Undo 与失败提示已接入；
- 搜索、来源、无标签、具体标签 accepted/rejected 与多标签 ALL/ANY 已接入既有 keyset 查询；
- 单选预览使用保留完整比例的 `preview` variant，网格继续使用 `gridRegular`；
- TDD 红灯证据：`/tmp/ImageAll-inspector-red-1.xcresult`、`/tmp/ImageAll-filter-red.xcresult`、`/tmp/ImageAll-multitag-red.xcresult`、`/tmp/ImageAll-tagfailure-red.xcresult`；
- Workspace、资产查询、标签事务、Composition Root 与派生图契约相关回归 61/61 通过：`/tmp/ImageAll-inspector-final.xcresult`；
- arm64 Debug build 成功；实际签名 entitlement 未扩张；
- 自动化未访问 `/Volumes/HDD2`，未运行真实 App 容器 smoke，未 push；
- 本轮由临时授权下的 Codex implementation 完成，未启动 Cursor CLI 任务。

已知延期：搜索在提交时执行，尚无输入 debounce；没有文件格式/可用状态筛选、排序控件、Space 单图模式、完整键盘导航、FSEvents、活动中心、扩展性能/无障碍验证或真实数据 smoke。
