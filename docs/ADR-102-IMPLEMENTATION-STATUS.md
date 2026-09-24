# ADR-102 实施状态

> 2026-09-24；ADR-102 仍为待评审提案。本记录只描述已经落地和验证的部分，不代表阶段验收通过。

## 当前切片

- iPhone App 新增“此 iPhone”入口，未配对 Mac 时仍可进入。本机照片授权在用户点按后请求，有限权限只展示获准资产；权限缩小时隐藏目录投影，不删除本地整理事实。
- PhotoKit 仅取本机用户图库资产的目录信息和按需缩略图；缩略图请求设置 `isNetworkAccessAllowed = false`。用户明确点按收藏按钮后可写回本机 Photos，写前保存目标、写后回读，失败保留待处理状态并允许重试；没有自动原件传输、媒体迁移或来源删除流程。
- App 自有 SQLite 保存安装身份、来源 epoch、稳定媒体 ID、标签决定、ImageAll 集合成员、收藏目标和来源写回状态。人工事实与本地审计 outbox 同事务写入；仅已显式分享资产进入 `shared_outbox`，共享资产的标签、集合和收藏目标变化与该记录同事务提交，使用稳定操作 ID 和序号。撤出分享会取消该资产的共享意图，不删除本地事实或审计历史；全量 outbox 不会发送到 Mac。用户可逐项加入或撤出“待分享”范围，并手动提交当前获准访问的目录和标签决定。范围默认空；权限收缩保留选择，提交时携带完整选中 ID 集合以区别显式撤销与临时不可见。Mac 回执指出首次导入的资产，手机持久确认快照范围、吸收该快照所含的旧整理意图，再把其后标签操作按字段版本和稳定操作 ID 提交；成功 ACK 推进本地版本。手机界面会显示同字段版本冲突的本机决定和已知 Mac 决定；用户明确选择采用 Mac，或保留当前本机决定并生成新的操作 ID/序号在下次同步重试。标签身份/同名不同 ID 的冲突仍保留待对账，不能直接覆盖。集合和收藏目标仍只排队，尚无跨端提交协议。单次目录提交当前限制为 200 KiB，超限会报错；大范围分页尚未实现。
- Mac 新增配对设备专用的本机目录快照接收路由和持久投影，绑定 Host、设备、安装和来源 epoch，拒绝迟到序号及来源身份变化。已共享资产暂时不可见时保留旧投影及最后可见的快照序号；只有从选中范围明确撤出才移除。原生 Bearer 请求可写入，浏览器 Cookie 写请求仍需同源验证。首次进入投影的资产会在快照回执中列出，包含先前已选中但因权限暂不可见、后来才进入投影的资产。针对已分享手机资产的标签决定，Mac 另存版本化共享事实与稳定操作回执：同字段按 base revision 判冲突，同操作 ID/负载重试返回原结果，迟到设备序号被拒绝，后来的手机目录快照不能覆盖已接纳决定；权限暂时不可见时拒绝新手机标签操作。Mac 可在手机目录界面修改**已有**共享标签决定，按期望版本写入同一持久账本及按设备过滤的变化页；iPhone 手动同步拉取后，事务性应用变化与 cursor，同字段本地待提交意图保留为冲突。此账本目前仍以单手机来源为范围，不是完整工作区标签提交中心。Mac 主图库侧栏把已收到的手机目录列为独立来源，进入后可检索元数据，并看到接收时间、共享标签版本、收藏观测/目标及暂未观测状态；Host 停止时仍可读取和修改已有标签。远程 Host 设置页复用该视图。当前没有共享缩略图或原件，手机来源不进入 Mac 本机资产编辑、删除和清理工具栏；跨来源正式标签、集合与收藏双向收敛尚未实现。
- 远程 Companion 仍在“Mac 图库”入口。旧 P0–P8 的图库、审核、标签、任务和预览工作流已移植到当前主线；补齐当前 Remote Client 对标签管理、撤销、审核概览和图库筛选的封装，保留主线已有 DTO 与 Host 能力。事件通道断开后可重试，旧连接迟到事件会被拒绝。当前组合已通过选定的合成 Host 路由测试，S0 的 iPhone 界面端到端验收尚未通过。

## 本轮证据

- 共享标签版本冲突新增明确的手机端选择：采用已知 Mac 决定只更新本地事实与审计；保留本机决定在已知 Mac revision 上生成新的共享操作 ID 和序号，原审计记录保留。标签身份和同名不同 ID 冲突保持待处理。合成 LocalLibrary 测试 11/11、RemoteProtocol 50/50、RemoteClient 52/52 通过；Mac 在 SSD1 独立 Products/Intermediates 的 `build-for-testing` 通过，版本回执及身份冲突路由 XCTest 各 1/1 通过；iOS Simulator 在 SSD1 的隔离构建通过。这些证据不包含实体设备操作。
- 已确认不再被本轮构建使用的 `/private/tmp/ImageAll-ADR102-*` 26 个隔离构建目录已定向删除，约释放 10 GiB；系统盘可用空间从约 11 GiB 升至 22 GiB。后续本轮 Mac/iOS 构建产物放在 `/Volumes/SSD1/.codex-builds/`。
- Mac 已有共享标签可按字段 revision 本地编辑，并原子写入按设备 scope 过滤的变化页；合成账本测试和配对 Bearer 路由 XCTest 各 1/1 通过，覆盖重启持久化、迟到 Mac 编辑拒绝、手机旧版本冲突、撤出分享不泄露旧变化，以及配对设备可读/未配对 Bearer 被拒绝。手机变化页与 cursor 同事务应用的本地库测试 9/9 通过，冲突保留手机决定且错误标签身份不推进 cursor；RemoteProtocol 49/49、RemoteClient 52/52 通过，iOS Simulator 在 SSD1 的隔离构建通过。仍缺实体设备与真正跨进程端到端验收。
- 本轮 `/tmp` 隔离构建曾把系统盘压至约 127 MiB，iOS 链接报空间不足；使用 `xcodebuild clean` 定向清理本目标不再需要的构建产物后，系统盘可用约 10 GiB，后续隔离 Mac/iOS 产物改放 `/Volumes/SSD1/.codex-builds/`。自定义 Products/Intermediates 的 Mac `build-for-testing` 完成编译与链接、直接 XCTest 可运行，但生成 `.xctestrun` 文件时 Xcode 报目标文件夹不存在；同一隔离产物目录的 Mac `build` 随后通过。使用项目默认 Products 设置的 Mac `build-for-testing` 通过，最新 bundle 的两项直接 XCTest 各 1/1 通过；核对构建设置发现默认 Products 实际位于 `/Volumes/SSD1/Xcode/DerivedData` 共享目录，不能把这次测试构建称为完全隔离，后续需显式指定独立 Products/Intermediates。
- Mac 隔离 `build-for-testing` 与 iOS Simulator 隔离 `build` 通过；直接执行新增事实账本、旧投影兼容和 HTTP 路由的合成 XCTest 3/3 通过，覆盖稳定操作 ID 重放、不同负载拒绝、同字段旧版本冲突、持久重启、后续快照不覆写、权限收缩禁止新操作、旧持久投影打开，以及配对 Bearer/浏览器 Cookie 边界。RemoteProtocol 49/49、RemoteClient 51/51 通过，客户端测试核对请求路径、Bearer、稳定操作 ID 与回执解码。手机手动同步现已调用标签决定接口，但尚无实体设备上的端到端收敛证据。
- `swift test --package-path Packages/ImageAllLocalLibrary`：8/8；合成测试覆盖私有资产不进入共享队列、操作 ID/顺序跨重启稳定、撤出分享取消未发送意图、事务回滚，以及新增的快照首次导入基线、同字段顺序提交、冻结版本重试、冲突跨重启保留与成功 ACK 推进下一操作版本。同一共享范围和可见集合下，未获 ACK 的快照原样持久重试，后续本地操作不被旧快照水位吸收。RemoteProtocol 49/49、RemoteClient 51/51 通过；iOS Simulator 目标的隔离 `xcodebuild build` 通过。此处尚无实体设备或跨进程端到端收敛证据。
- 本轮 Mac 独立 Products/Intermediates 的 `build-for-testing` 通过；直接执行目录投影 XCTest 1/1 通过，覆盖权限暂不可见的已选资产恢复可见后首次导入的回执，以及原有迟到重放和明确撤销边界。测试只使用合成目录，不接触受保护真实图库。
- 主图库侧栏独立手机来源和只读目录浏览改动后，隔离 Products/Intermediates 的 Mac `xcodebuild build-for-testing` 通过；静态核对显示该来源不进入本机图库键盘操作、资产工具栏和检查器。尚未在日常 App 实际点击验收，也未验证实体 iPhone 的目录提交后显示。
- Mac 设置页只读查看器改动后，独立 Products/Intermediates 的 `xcodebuild build-for-testing` 通过；直接执行投影 XCTest 1/1 通过，覆盖保存接收时间、Host 停止时按持久文件重建的投影枚举以及旧有隐藏/撤销/迟到回放边界。尚未更新日常 App 或完成实际界面验收。
- `swift test --package-path Packages/ImageAllLocalLibrary`：3/3；隔离 fixture 验证重启后身份、事实和操作 ID 保持，授权可见范围缩小时事实不被清除；收藏失败状态与迟到回执；共享范围默认关闭、只输出所选且当前可见的资产及引用事实、重启保留选择和撤销推进范围版本。新增快照序号跨重启递增，隐去目录项仍保留显式选中 ID。
- `swift test --package-path Packages/ImageAllRemoteProtocol`：49/49；新增共享快照 DTO 回环，明确区分选中 ID 与当前可见负载。
- `swift test --package-path Packages/ImageAllRemoteClient`：50/50；新增原生客户端携 Bearer 提交快照的请求/回执测试。
- `xcodebuild build -project ImageAllMobile.xcodeproj -scheme ImageAllMobile -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`：构建通过。
- `xcodebuild build -project ImageAllMobile.xcodeproj -scheme ImageAllMobile -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`：构建通过。
- 收藏写回改动后两种 iOS 目的地重新构建通过。模拟器首次并行构建因项目共享 `build.db` 锁退出，随后指定独立 Products/OBJROOT 顺序重跑通过。
- 本轮 Mac `build-for-testing` 在隔离 Products/Intermediates 中通过；直接执行 `ImageAllTests.xctest` 的 2 项新增合成测试通过：持久投影、权限收缩、重启回放、显式撤销、迟到序号，以及路由只接受配对设备、原生 Bearer 可提交而无同源 Cookie 被拒绝。
- 提交 `64596429` 后另建干净 detached worktree，向其私有目录复制 OpenMontage Runtime 依赖；该提交独立完成隔离 Mac `build-for-testing`、上述两项直接 XCTest 和 iOS Simulator 构建。没有把共享 Runtime 种子作为构建输出目录，也没有将并行 OpenMontage 草稿纳入提交。
- 当前主线 Mac `build-for-testing` 在独立 Products/Intermediates 中通过；直接执行 `ImageAllTests.xctest` 的 6 项合成 Host 测试通过：高级图库筛选、原子建标签并应用、标签撤销回放、审核概览、配对和视频 Range。使用直接 XCTest，未启动生产 App 测试宿主。首次无签名构建因现有 OpenMontage 脚本要求 `embedded.provisionprofile` 失败；改用项目原有签名设置并隔离构建输出后通过。
- 本轮测试只用合成身份、临时 SQLite/JSON 和独立 XCTest bundle；没有访问 HDD2 受保护照片，没有启动生产 Photos 测试宿主，也没有执行源端写入。当前 Mac/iOS 代码构建通过，尚未更新日常 App；OpenMontage 发布门禁和实际界面验收仍待执行。

## 尚需完成的阶段门

1. S0：当前组合已构建并通过选定合成 Host 路由测试；仍需 iPhone App 对合成 Host 的图库/审核/标签/视频/连接界面运行回归，以及实体设备触摸、网络切换和 Mac 日常 App 实际交互。Host 路由测试不等于 iPhone 端到端验收。
2. S1：真机有限/拒绝权限、离线重启、收藏 PhotoKit 写回与来源回读的实际验收；假 PhotoKit 测试、本地事实导出和长期数据库恢复策略。现有 SQLite 合成测试与构建不能证明真实权限及 Photos 行为。
3. S2：已具备用户选取、手动提交、Mac 持久接收和主图库侧栏查看的单批目录/事实路径，手机端已分享资产的事务性待同步队列，以及 Mac 单手机来源的版本化标签决定与幂等回执。手机手动同步会确认首次导入基线、发送后续标签队列并拉取 Mac 对已有标签的修改；成功/一致回执移除共享待发送项，Mac 变化与 cursor 同事务应用，同字段冲突持久保留；用户可明确处理版本冲突，保留本机选择会以新操作重试；同一范围和可见集合的快照 ACK 丢失可原样重试。仍需标签身份与同名不同 ID 冲突的对账、跨来源正式标签身份、一致快照与分页增量、集合/收藏字段冲突、撤销、长离线及权限变更对账；范围或可见集合在快照 ACK 丢失后变化时，旧快照与新快照之间的对账仍未完成。按需预览属于后续 S5；现有手动标签同步不能称为 S2 验收。
4. S3–S6：媒体资源归档、逐资源校验与独立恢复、冗余清理安全门、手机来源命令及后续优化均尚未实施。

实体 iPhone 验收按 ADR-102 等待所有者明确手机已重新连接；此前构建和合成测试不能代替真机证据。任何真实照片写入、删除、下载或迁移仍受 `docs/LOCAL-TEST-DATA-SAFETY.md` 单次授权边界约束。
