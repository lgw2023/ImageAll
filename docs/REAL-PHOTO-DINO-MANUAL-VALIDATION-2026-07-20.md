# App 内 DINO 真实照片人工验证 Runbook

> 状态：Authorized；等待项目所有者在 production App 内人工执行
> 日期：2026-07-20
> 开工基线：`main@c5d5eb8ab4db0668ffd1bcf70764c7dc2d7bd382`
> 数据级别：受保护真实数据；本授权只对本次 runbook 有效

## 1. 项目所有者授权与实施假设

项目所有者授权在 HDD2 图库挂载期间启动 ImageAll production App，仅通过 PhotoKit 只读访问
`/Volumes/HDD2/Photos Library.photoslibrary`；由项目所有者手工选择 100 张当前资产，为一个个人标签
标注，逐张显式准备特征后显式重建个人模型。允许输出仅写入 App 自身容器；不得遍历图库包、触发
iCloud 下载、批量扫描或写入源图库；完成原生 head 激活与失败隔离验证后停止。

授权原文没有指定 accepted/rejected 分配。本 runbook 默认建议 `50 accepted + 50 rejected`；项目所有者
可以在操作时采用其他比例，但两类都必须至少有 2 张，且本次总数不得超过 100 张。标签名称和任何照片
标识不写入评审证据。

## 2. 精确边界

- 输入只能是当前系统照片图库中由项目所有者在 UI 内逐张选中的静态照片；绝对路径仅用于标识受保护
  图库，App 和命令行都不得把它作为文件系统输入；
- 只有项目所有者可以在 Photos 中打开、切换或设定 System Photo Library；Codex 和自动化不得代为操作；
- 生产 App 只经 PhotoKit 读取当前资产的 local-only preview，不请求 iCloud-only 原图；
- App 只写自身 sandbox container 中的事实库、`Caches/ImageAll` 和
  `Application Support/ImageAll`；禁止向 Photos 或图库包反向写入；
- 不运行 App 测试宿主，不用脚本点击、枚举或批量选择真实资产，不记录照片内容、Photos local
  identifier、bookmark 或逐项路径；
- 不接全库 DINO 扫描、批量预热、后台任务、Review Queue 或个人建议展示。

## 3. 启动前安全门

1. `HEAD == origin/main`，工作区干净；
2. `/Volumes/HDD2/Photos Library.photoslibrary` 仅做挂载存在性检查，不列举包内容；
3. production Swift 源码静态搜索不得出现 `PHAssetChangeRequest`、PhotoKit `performChanges`、
   `creationRequestForAsset`、`deleteAssets` 或 collection change request；
4. 从当前 HEAD 构建独立 Release App，验证签名与 production bundle identity；
5. 项目所有者确认 Photos 当前使用的 System Photo Library 正是上述受保护图库；若不是，停止，由项目
   所有者自行决定是否切换。

## 4. 人工步骤

1. 启动本次 Release App；若系统请求 Photos 权限，由项目所有者确认；
2. 在 Settings 启用 App 内本地模型，等待固定 Core ML artifact 显示 ready；
3. 进入 Apple Photos 来源并创建或选择一个个人标签；
4. 逐张选择恰好一个 local-only 资产，设置该标签的 accepted 或 rejected 人工事实，再点击
   “准备当前照片特征”；重复至总计 100 张，建议 50/50；遇到 iCloud-only 提示就跳过，不发起下载；
5. 点击“重建个人模型”，等待 App 内 Swift/Accelerate head 成功激活；
6. 关闭本地模型后，对一个当前选择调用一次“准备当前照片特征”，确认模型不可用提示不会阻止浏览或
   人工标签；随后可重新启用模型，但不得启动任何外部服务；
7. 记录聚合 accepted/rejected 数、成功准备特征数、跳过数、稳定错误码和 head capability 状态，不记录
   逐项身份或图片内容，然后退出 App。

## 5. 验收与停止位置

- 100 张人工选择全部由项目所有者完成，accepted/rejected 各至少 2；
- 每个成功样本只由显式单资产动作产生当前完整 encoder identity 的一个版本化 embedding；
- 原生个人 head 只在事实快照仍为 current、cache 完整且 identity 匹配时激活；
- 模型关闭、iCloud-only、cache miss 或单次失败不影响浏览和人工标签；
- production App 不启动 Python、uv、loopback HTTP、helper/XPC；
- production 源码没有 Photos mutation API，人工运行未执行源端写入；所有新产物只在 App 容器；
- 完成上述聚合验证后退出 App 并停止，不继续全库扫描、批量建议或更多真实数据处理。

## 6. 本次证据记录

| 项目 | 结果 |
|---|---|
| Release commit / bundle | 待启动前补记 |
| production mutation API 静态检查 | 通过；未发现匹配项 |
| 用户实际 accepted / rejected | 待人工完成 |
| 成功准备 / local-only 跳过 / 失败 | 待人工完成 |
| 原生 head capability | 待人工完成 |
| 失败隔离 | 待人工完成 |
| 源端写入 | 预期为零；待人工完成后按聚合证据收口 |
| 停止位置 | 待退出 App 后关闭 |
