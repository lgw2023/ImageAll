# ADR-102 实施状态

> 2026-09-24；ADR-102 仍为待评审提案。本记录只描述已经落地和验证的部分，不代表阶段验收通过。

## 当前切片

- iPhone App 新增“此 iPhone”入口，未配对 Mac 时仍可进入。本机照片授权在用户点按后请求，有限权限只展示获准资产；权限缩小时隐藏目录投影，不删除本地整理事实。
- PhotoKit 仅取本机用户图库资产的目录信息和按需缩略图；缩略图请求设置 `isNetworkAccessAllowed = false`。用户明确点按收藏按钮后可写回本机 Photos，写前保存目标、写后回读，失败保留待处理状态并允许重试；没有自动原件传输、媒体迁移或来源删除流程。
- App 自有 SQLite 保存安装身份、来源 epoch、稳定媒体 ID、标签决定、ImageAll 集合成员、收藏目标和来源写回状态。人工事实与待同步操作在同一事务写入；全量 outbox 不会发送到 Mac。用户可逐项加入或撤出“待分享”范围，并在独立页面手动提交当前获准访问的目录和关联整理事实。范围默认空；权限收缩保留选择，提交时携带完整选中 ID 集合以区别显式撤销与临时不可见。单次提交当前限制为 200 KiB，超限会报错；大范围分页尚未实现。
- Mac 新增配对设备专用的本机目录快照接收路由和持久投影，绑定 Host、设备、安装和来源 epoch，拒绝迟到序号及来源身份变化。已共享资产暂时不可见时保留旧投影及最后可见的快照序号；只有从选中范围明确撤出才移除。原生 Bearer 请求可写入，浏览器 Cookie 写请求仍需同源验证。当前投影尚未纳入 Mac 图库 UI 或正式跨端冲突/增量日志，回执只证明这一批目录数据被接收，不证明整理信息已双向收敛。
- 远程 Companion 仍在“Mac 图库”入口。旧 P0–P8 的图库、审核、标签、任务和预览工作流已移植到当前主线；补齐当前 Remote Client 对标签管理、撤销、审核概览和图库筛选的封装，保留主线已有 DTO 与 Host 能力。事件通道断开后可重试，旧连接迟到事件会被拒绝。当前组合已通过选定的合成 Host 路由测试，S0 的 iPhone 界面端到端验收尚未通过。

## 本轮证据

- `swift test --package-path Packages/ImageAllLocalLibrary`：3/3；隔离 fixture 验证重启后身份、事实和操作 ID 保持，授权可见范围缩小时事实不被清除；收藏失败状态与迟到回执；共享范围默认关闭、只输出所选且当前可见的资产及引用事实、重启保留选择和撤销推进范围版本。新增快照序号跨重启递增，隐去目录项仍保留显式选中 ID。
- `swift test --package-path Packages/ImageAllRemoteProtocol`：49/49；新增共享快照 DTO 回环，明确区分选中 ID 与当前可见负载。
- `swift test --package-path Packages/ImageAllRemoteClient`：50/50；新增原生客户端携 Bearer 提交快照的请求/回执测试。
- `xcodebuild build -project ImageAllMobile.xcodeproj -scheme ImageAllMobile -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`：构建通过。
- `xcodebuild build -project ImageAllMobile.xcodeproj -scheme ImageAllMobile -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`：构建通过。
- 收藏写回改动后两种 iOS 目的地重新构建通过。模拟器首次并行构建因项目共享 `build.db` 锁退出，随后指定独立 Products/OBJROOT 顺序重跑通过。
- 本轮 Mac `build-for-testing` 在隔离 Products/Intermediates 中通过；直接执行 `ImageAllTests.xctest` 的 2 项新增合成测试通过：持久投影、权限收缩、重启回放、显式撤销、迟到序号，以及路由只接受配对设备、原生 Bearer 可提交而无同源 Cookie 被拒绝。
- 当前主线 Mac `build-for-testing` 在独立 Products/Intermediates 中通过；直接执行 `ImageAllTests.xctest` 的 6 项合成 Host 测试通过：高级图库筛选、原子建标签并应用、标签撤销回放、审核概览、配对和视频 Range。使用直接 XCTest，未启动生产 App 测试宿主。首次无签名构建因现有 OpenMontage 脚本要求 `embedded.provisionprofile` 失败；改用项目原有签名设置并隔离构建输出后通过。
- 本轮测试只用合成身份、临时 SQLite/JSON 和独立 XCTest bundle；没有访问 HDD2 受保护照片，没有启动生产 Photos 测试宿主，也没有执行源端写入。当前 Mac/iOS 代码构建通过，尚未更新日常 App；OpenMontage 发布门禁和实际界面验收仍待执行。

## 尚需完成的阶段门

1. S0：当前组合已构建并通过选定合成 Host 路由测试；仍需 iPhone App 对合成 Host 的图库/审核/标签/视频/连接界面运行回归，以及实体设备触摸、网络切换和 Mac 日常 App 实际交互。Host 路由测试不等于 iPhone 端到端验收。
2. S1：真机有限/拒绝权限、离线重启、收藏 PhotoKit 写回与来源回读的实际验收；假 PhotoKit 测试、本地事实导出和长期数据库恢复策略。现有 SQLite 合成测试与构建不能证明真实权限及 Photos 行为。
3. S2：已具备用户选取、手动提交与 Mac 持久接收的单批目录/事实路径；仍需把手机来源纳入 Mac 图库、双向本地 mutation 入日志、一致快照与分页增量、按字段冲突、ACK/撤销、长离线及权限变更对账。当前 outbox 不是已完成的同步日志，不得直接发送全量 outbox；单批回执不能称为 S2 验收。
4. S3–S6：媒体资源归档、逐资源校验与独立恢复、冗余清理安全门、手机来源命令及后续优化均尚未实施。

实体 iPhone 验收按 ADR-102 等待所有者明确手机已重新连接；此前构建和合成测试不能代替真机证据。任何真实照片写入、删除、下载或迁移仍受 `docs/LOCAL-TEST-DATA-SAFETY.md` 单次授权边界约束。
