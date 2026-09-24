# ADR-102 实施状态

> 2026-09-24；ADR-102 仍为待评审提案。本记录只描述已经落地和验证的部分，不代表阶段验收通过。

## 当前切片

- iPhone App 新增“此 iPhone”入口，未配对 Mac 时仍可进入。本机照片授权在用户点按后请求，有限权限只展示获准资产；权限缩小时隐藏目录投影，不删除本地整理事实。
- PhotoKit 仅取本机用户图库资产的目录信息和按需缩略图；缩略图请求设置 `isNetworkAccessAllowed = false`。当前没有原件传输、媒体迁移或来源删除流程。
- App 自有 SQLite 保存安装身份、来源 epoch、稳定媒体 ID、标签决定、ImageAll 集合成员和收藏目标。人工事实与待同步操作在同一事务写入；当前没有网络提交器，待同步队列不会向 Mac 发送内容。
- 远程 Companion 仍在“Mac 图库”入口。旧 P0–P8 分支尚未适配当前主线，S0 未通过。

## 本轮证据

- `swift test --package-path Packages/ImageAllLocalLibrary`：隔离 fixture 验证重启后身份、事实和操作 ID 保持，授权可见范围缩小时事实不被清除。
- `xcodebuild build -project ImageAllMobile.xcodeproj -scheme ImageAllMobile -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`：构建通过。
- `xcodebuild build -project ImageAllMobile.xcodeproj -scheme ImageAllMobile -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`：构建通过。
- 全部测试只用新建的临时 SQLite；没有访问 HDD2 受保护照片，没有启动生产 Photos 测试宿主，也没有执行源端写入。

## 尚需完成的阶段门

1. S0：选择性适配 P0–P8 至当前 Remote Protocol / Client，完成当前 iOS 工作流的构建及合成回归。
2. S1：真机有限/拒绝权限与离线重启验收；本机收藏的 PhotoKit 写回与来源回读状态；本地事实导出和长期数据库恢复策略。
3. S2：明确分享范围、设备/工作区身份绑定、Mac 事务日志、快照与增量、冲突、ACK 和撤销。当前 outbox 只是本机持久事实的先导，不是已实现同步协议。
4. S3–S6：媒体资源归档、逐资源校验与独立恢复、冗余清理安全门、手机来源命令及后续优化均尚未实施。

实体 iPhone 验收按 ADR-102 等待所有者明确手机已重新连接；此前构建和合成测试不能代替真机证据。任何真实照片写入、删除、下载或迁移仍受 `docs/LOCAL-TEST-DATA-SAFETY.md` 单次授权边界约束。
