# ADR-076：停用来源只能显式重新启用

- 状态：已决定（2026-09-16）
- 范围：macOS ImageAll、内置 Web Companion、Apple Photos 来源生命周期与后台活动
- 取代：ADR-049 中“底层停用仅作兼容、不再提供用户入口”的部分产品决定

## 背景

`source.state = disabled` 表示用户明确要求停止来源工作。此前仍有两个通用入口会把该状态恢复为
`active`：`PhotosLibraryConnectionService.connect()` 会复用任意非 `unavailable` 的 Photos 来源，
批量访问授权也把 `disabled` Photos 当作缺少授权的目标。两者都可能在没有单独说明“重新启用”的
情况下恢复 PhotoKit 观察并排入同步任务。

同时，来源菜单只保留“删除来源…”，没有保留索引但停止同步的可见操作。后台任务经历失败与退避后
会从 `retryableFailed` 收敛回 `pending`，活动面板只显示“等待中”，无法区分首次排队和失败后的等待
重试。

PhotoKit 的图库可用性观察只保证状态变化通知。若 ImageAll 启动时系统照片图库已经不可用，观察器
可能收不到新的回调；旧实现会继续把来源保留为 `active`，并把同步阶段抛出的
`PhotosLibraryError.libraryUnavailable` 兜底归类成 `photosPersistenceFailure`。结果是活动面板长期显示
“索引保存失败 / 等待重试”，但真实问题其实是当前系统照片图库不可用。

此外，`PHPhotoLibrary.unavailabilityReason` 可能在 PhotoKit 尚未真正绑定系统图库时仍为 `nil`；首次读取
持久变更历史才会通过 Photos/XPC 后端返回打开图库失败。旧适配器把所有这类错误都折叠成
`changeTokenInvalid`，而任务运行器又没有在 `not_before_ms` 到期时主动唤醒，导致失败任务只能依赖以后
某次无关事件偶然重试。

## 决策

1. `disabled` 是独立的用户意图，不属于访问授权缺失。
2. 普通“连接 Apple Photos”只能创建新来源，或复用 `active / authorizationRequired` 来源；发现只有
   `disabled` 或历史 `unavailable` 来源时不得改写状态，也不得排入任务。
3. 批量访问授权只处理 `unavailable / authorizationRequired` 文件夹和
   `authorizationRequired` Apple Photos，必须跳过 `disabled` 来源。
4. 活跃 Apple Photos 来源重新提供“停用来源…”：停止 PhotoKit 观察并取消或请求取消相关同步任务，
   保留 Source、Asset、人工标签和 App 缓存。该操作与“删除来源…”并列，语义不可互换。
5. 停用后的 Apple Photos 只能通过该来源自己的“重新启用…”确认恢复。确认文案必须说明会恢复观察并
   排入增量同步；普通连接、App 启动恢复和批量授权均不得代替该确认。
6. 活动投影保留安全错误码和尝试次数。`pending` 且存在上次错误时显示“等待重试”，并给出安全的失败
   摘要与尝试次数，不显示底层异常消息或照片内容。
7. 注册 PhotoKit 观察前必须主动读取当前图库可用状态。若启动时已经不可用，立即把活跃 Photos 来源
   置为 `unavailable`、停止观察并取消其待执行同步任务；不得先排入 catch-up 扫描。
8. 同步处理器仍需作为竞态兜底：枚举期间遇到 `libraryUnavailable` 时，在同一数据库事务内停用当前
   来源工作并以 `photosSourceUnavailable` 结束任务，保留已有 Asset、标签和缓存；不得再误报为索引
   持久化失败或继续无意义重试。
9. PhotoKit 持久变更读取只把 Apple 明确定义的“游标过期”和“变更详情不可用”归类为
   `changeTokenInvalid`。权限错误保持权限语义；图库离线、切换、后端绑定/XPC 失败及其他读取后端错误
   一律归类为 `libraryUnavailable`。调用方批次写入抛出的本地数据库错误必须原样越过 PhotoKit 映射
   边界，继续按 `photosPersistenceFailure` 处理。
10. Folder / Photos 对账运行器在领取任务前先结算已到期的 `retryableFailed`；若重试时间尚未到，模型
    按活动投影中的最早 `not_before_ms` 安排一次精确唤醒。不得忙轮询，也不得依赖其他 UI 或后台事件
    偶然唤醒。

## 安全与兼容性

- 停用、重新启用和任务状态展示只修改 ImageAll 自有数据库与任务调度，不读取或修改 Apple Photos
  原图。
- 历史 `disabled` 来源继续保留，可显式重新启用或删除。
- `authorizationRequired` 仍属于授权恢复路径；本决策不把权限丢失误写成用户停用。
- 文件夹来源的历史 `disabled` 兼容行为保持不变；本切片不新增文件夹重新启用入口。

## 验证标准

- 合成数据库中，普通 connect 面对 disabled Photos 时保持状态和 `updated_at_ms` 不变且不产生任务；
  显式 reactivate 才改为 active 并产生一个同步任务。
- Mac 模型与 Remote Host 的批量授权均跳过 disabled Photos，显式单来源重新启用仍然有效。
- 活动查询能把失败码和尝试次数投影到 UI；失败后已回到 pending 的任务显示“等待重试”。
- 合成“启动前图库已不可用”状态时，不注册 PhotoKit 观察、不排 catch-up，来源变为 unavailable，待
  执行任务被取消且既有照片事实保持不变。
- 合成“观察器漏过状态变化、枚举才发现不可用”竞态时，任务以 photosSourceUnavailable 终止、来源
  变为 unavailable，既有照片事实保持不变。
- 合成 PhotoKit 游标过期、权限失败和后端打开失败时，分别映射为 changeTokenInvalid、授权错误和
  libraryUnavailable；合成本地批次写入失败时仍保留 persistenceFailure。
- 活动投影保留 `not_before_ms`，到期重试无需新的文件系统、PhotoKit 或 UI 事件即可重新领取；达到最大
  尝试次数的任务不得再次安排。
- 自动化只使用临时数据库与合成 Photos 适配器，不访问 `/Volumes/HDD2` 或真实 Photos 图库。
