# ImageAll 阶段 1 加速交付计划

> 状态：Slice A implemented and approved
> 日期：2026-07-15  
> 设计基线：`main@a03d1296b4f7ffa22de369baebc89042ea94283f`
> 实现：`main@0e7dd655f99a57730025355fde6bacdff564e0f4`

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

## 3. 明确延期

以下内容不进入加速切片 A：

- FSEvents watcher、dirty trigger 与自动增量重扫；
- Activity 工作区、任务列表、暂停、取消、重试；
- Inspector、标签、搜索、筛选、`Command-K`；
- 多窗口状态同步、复杂选择语义、Space 单图查看；
- 10,000/100,000 项性能基准、完整无障碍矩阵和所有故障注入；
- 真实 `/Volumes/HDD2` 数据 smoke。

这些项目进入阶段 1 技术债清单，后续按对实际使用价值的影响排序补回。延期不包括来源只读、bookmark 生命周期、目录边界、原子数据库写入、派生缓存路径安全和真实照片保护。

## 4. 最小验证门

为了加快交付，本切片只要求：

1. 一个公开界面级模型测试证明“空库可连接，成功后执行扫描并出现照片”；
2. 一个失败测试证明连接/扫描失败进入安全错误状态且不会伪装为空库；
3. 相关既有授权、对账、查询和派生图测试保持通过；
4. arm64 Debug build 成功；
5. entitlement、privacy manifest 和 `/Volumes/HDD2` 零访问边界不变。

不再为本切片新增重复 schema introspection、全量 fault matrix 或实现细节测试。若最小回归发现既有缺陷，只修复阻塞主路径的问题，其余记录后置。

## 5. 停止位置

加速切片 A 完成后先进行可运行 App 评审。下一纵切片优先加入 Inspector 人工标签与基础搜索筛选；是否先补 watcher/活动能力，以首个闭环的实际使用反馈决定。

## 6. 切片 A 验收记录

2026-07-15 已完成并通过：

- 启动 gate 成功后由 Composition Root 组装授权、reconcile Job、目录查询和派生图缓存；
- 空库只读说明、用户触发的系统目录选择、来源侧栏、手动重扫、分页方形网格和按需 `gridRegular` 缩略图已接入；
- TDD 红灯证据：`/tmp/ImageAll-accelerated-red.xcresult`；目标模型测试 2/2 通过；
- 相关授权、对账、查询、派生图与 Composition Root 回归 62/62 通过：`/tmp/ImageAll-accelerated-related.xcresult`；
- arm64 Debug build 成功；entitlement 与 privacy manifest 未改；
- 自动化未访问 `/Volumes/HDD2`，未运行真实 App 容器 smoke，未 push。

已知延期：扫描完成后才整体刷新网格；没有 FSEvents、活动中心、标签、搜索筛选、单图查看或真实数据 smoke。这些缺口不阻塞切片 A 的“连接—扫描—浏览”闭环。
