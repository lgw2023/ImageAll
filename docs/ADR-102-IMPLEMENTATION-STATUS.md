# ADR-102 实施状态

> 2026-09-24；ADR-102 仍为待评审提案。本记录只描述已经落地和验证的部分，不代表阶段验收通过。

## 当前切片

- iPhone App 新增“此 iPhone”入口，未配对 Mac 时仍可进入。本机照片授权在用户点按后请求，有限权限只展示获准资产；权限缩小时隐藏目录投影，不删除本地整理事实。
- PhotoKit 仅取本机用户图库资产的目录信息和按需缩略图；缩略图请求设置 `isNetworkAccessAllowed = false`。用户明确点按收藏按钮后可写回本机 Photos，写前保存目标、写后回读，失败保留待处理状态并允许重试；没有自动原件传输、媒体迁移或来源删除流程。
- App 自有 SQLite 保存安装身份、来源 epoch、稳定媒体 ID、标签决定、ImageAll 集合成员、收藏目标和来源写回状态。人工事实与待同步操作在同一事务写入；当前没有网络提交器，待同步队列不会向 Mac 发送内容。
- 远程 Companion 仍在“Mac 图库”入口。旧 P0–P8 的图库、审核、标签、任务和预览工作流已移植到当前主线；补齐当前 Remote Client 对标签管理、撤销、审核概览和图库筛选的封装，保留主线已有 DTO 与 Host 能力。事件通道断开后可重试，旧连接迟到事件会被拒绝。当前组合已通过选定的合成 Host 路由测试，S0 的 iPhone 界面端到端验收尚未通过。

## 本轮证据

- `swift test --package-path Packages/ImageAllLocalLibrary`：2/2；隔离 fixture 验证重启后身份、事实和操作 ID 保持，授权可见范围缩小时事实不被清除；收藏失败状态、来源回读、迟到回执不覆盖新目标，以及来源后续变化使匹配状态失效。
- `xcodebuild build -project ImageAllMobile.xcodeproj -scheme ImageAllMobile -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`：构建通过。
- `xcodebuild build -project ImageAllMobile.xcodeproj -scheme ImageAllMobile -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`：构建通过。
- 收藏写回改动后两种 iOS 目的地重新构建通过。模拟器首次并行构建因项目共享 `build.db` 锁退出，随后指定独立 Products/OBJROOT 顺序重跑通过。
- `swift test --package-path Packages/ImageAllRemoteClient`：49/49；覆盖事件通道恢复状态、旧连接回调隔离、图库筛选请求和 P0–P8 窄路由的请求/回执。
- 当前主线 Mac `build-for-testing` 在独立 Products/Intermediates 中通过；直接执行 `ImageAllTests.xctest` 的 6 项合成 Host 测试通过：高级图库筛选、原子建标签并应用、标签撤销回放、审核概览、配对和视频 Range。使用直接 XCTest，未启动生产 App 测试宿主。首次无签名构建因现有 OpenMontage 脚本要求 `embedded.provisionprofile` 失败；改用项目原有签名设置并隔离构建输出后通过。
- 全部测试只用新建的临时 SQLite；没有访问 HDD2 受保护照片，没有启动生产 Photos 测试宿主，也没有执行源端写入。

## 尚需完成的阶段门

1. S0：当前组合已构建并通过选定合成 Host 路由测试；仍需 iPhone App 对合成 Host 的图库/审核/标签/视频/连接界面运行回归，以及实体设备触摸、网络切换和 Mac 日常 App 实际交互。Host 路由测试不等于 iPhone 端到端验收。
2. S1：真机有限/拒绝权限、离线重启、收藏 PhotoKit 写回与来源回读的实际验收；假 PhotoKit 测试、本地事实导出和长期数据库恢复策略。现有 SQLite 合成测试与构建不能证明真实权限及 Photos 行为。
3. S2：明确分享范围、设备/工作区身份绑定、Mac 事务日志、快照与增量、冲突、ACK 和撤销。当前 outbox 只是本机持久事实的先导，不是已实现同步协议。
4. S3–S6：媒体资源归档、逐资源校验与独立恢复、冗余清理安全门、手机来源命令及后续优化均尚未实施。

实体 iPhone 验收按 ADR-102 等待所有者明确手机已重新连接；此前构建和合成测试不能代替真机证据。任何真实照片写入、删除、下载或迁移仍受 `docs/LOCAL-TEST-DATA-SAFETY.md` 单次授权边界约束。
