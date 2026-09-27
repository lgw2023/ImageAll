# 视频能力补全推进记录

更新：2026-09-27。目标工具状态 active；任务范围为目标提示词 P0–P7，不含第 10 节扩展。

## 工作区与边界

- 主工作区 `/Volumes/SSD1/ImageAll`，`main`，启动 HEAD `2cfb9f54842f6f5ede4cd24cb42fe044c82a3021`。
- 网页工作区 `/Volumes/SSD1/ImageAll-Web-Dev`，`lgw/imageall-web-dev`，启动 HEAD `0e985848c898f0aab120da86dd0d005d5448a50a`。
- 基线状态、已有 diff 和未跟踪文件摘要保存在 `/Volumes/SSD1/.codex-builds/video-completion-20260927/`。后续构建、fixture、日志也使用此独立 SSD1 根，不覆盖共享 DerivedData。
- 启动已有 OpenMontage、TimeStory、LibraryWorkspace、手机本地图库及归档／协议迁移改动；均不归本目标。网页已有审核界面、地图与生成资源改动；不整体暂存或合并。
- 已读取会话列表：ADR-102 手机同步会话 active；不发消息、不建新会话、不启动子代理。同文件以最小独立 hunk 处理；提交前再次审计。
- 当前 AGENTS 优先于 DEVELOPMENT / ADR-072 中旧的独立日常 App 表述：以 Xcode 项目验收，不替换 App。
- 测试采用 Swift package 合成测试及 build-for-testing 后的直接 XCTest；禁止生产 Photos 宿主。直接 bundle 运行前逐项检查测试初始化与 fixture。

## 阶段与下一步

| 阶段 | 工程状态 | 验证 | 当前切片 |
|---|---|---|---|
| P0 | VERIFIED | PASS（静态盘点） | 基线、边界、首个切片与测试路径明确；不等于功能通过 |
| P1 | IN_PROGRESS | 分切片 PASS；完整闭环未验 | 媒体契约已交付；Mac／iPhone 查看器构建／合成测试 PASS；跨端联调待补 |
| P2 | NOT_STARTED | NOT_RUN | 文件夹视频时间与位置，再接筛选／地图／显式云端获取 |
| P3 | NOT_STARTED | NOT_RUN | 复核代表帧模型隔离，接远端建议与审核持久事实 |
| P4 | NOT_STARTED | NOT_RUN | 有界完整字节摘要、修订复核、合成回收恢复 |
| P5 | NOT_STARTED | NOT_RUN | 版本化有限多帧与时间点证据、内容相似独立候选 |
| P6 | NOT_STARTED | NOT_RUN | 显式片段与原声规则，合成混合故事可解码验证 |
| P7 | NOT_STARTED | NOT_RUN | 必需集成、最终构建与人工路线 |

首个切片输入：生产 `AssetGridItemProjection.mediaKind` / `AssetInspectorDetail.mediaKind`；输出：摘要／详情 DTO 显式字段，兼容已知 UTI 和 MIME，未知格式明确不可用；验收：新旧 JSON、MP4／MOV／照片／未知类型、Web 分支与相关构建。不能据此宣称完整 P1 通过。

## 能力矩阵（启动静态核查，不代表运行通过）

| 能力／来源 | Mac | Web | iPhone Companion |
|---|---|---|---|
| 文件夹、本地 PhotoKit 视频浏览 | 图库／审核／瘦身共用播放器已实现，控制器／模型合成 PASS；UI 待验 | UTI／显式媒体域视频分支通过合成验证，主线集成待办 | 认证分段播放已实现，合成解码／seek PASS；实体设备待验 |
| 云端原件不可用 | 本地视频请求默认禁下载；显式获取待做 | 不得借照片下载状态冒充视频支持 | 待核明确失败状态 |
| 手机独立归档 | 由 ADR-102 并行实施；不等同主图库视频身份 | 不适用当前主资产闭环 | 独立本地图库不在本目标重建 |
| 视频时间／GPS／地图 | 文件夹视频时间 nil；地图 SQL 限 image | 依赖 Host，未验 | 依赖 Host，未验 |
| 标签／审核／AI | 已有视频域，需合成串联 | 远端建议部分硬编码 image | 共享 Host 持久事实，未验 |
| 完整视频精确去重 | 待复核并补全 | 比较入口待对齐 | 能力声明待对齐 |
| 多帧／混合故事 | 故事仍筛 image；多帧待做 | 按支持入口声明 | 按支持入口声明 |

## 待集成与证据

- Web 必须在专用分支修改；必需切片的主线集成待准备可审查提交，不合并整个长期分支。
- Web 本地提交 `f84bff8b`：显式媒体域 schema、UTI/MIME 兼容、查看器／网格／Inspector／批量操作域选择、契约与浏览器合成测试。未包含已有审核、地图与生成资源改动；未 push。
- Web 必需主线集成：`f84bff8b` 的 8 个源码／测试文件已逐字节集成 main；未合并长期分支。当前生产网页生成资源仍不包含该结果，资源集成待单独处理，不能宣称 Xcode 内置网页已更新。
- Swift 摘要／详情新增可选媒体域与兼容解析；Host 两个投影显式传领域媒体域。Mac 构建与直接 XCTest 已通过。
- 下一条动作：主线契约提交 `6cc5a6ca` 已保存；Mac 播放器已提交 `83c5ceb1`；iPhone 认证播放本轮收尾后，继续 Web 必需集成与跨端联调。
- 已确认复用点：`LibraryVideoPlaybackProviding` / `LibraryVideoPlaybackResource` 与既有 hover 生命周期测试；审核投影无媒体域但队列已有 `selectedMediaKind`；iPhone 当前仍解码图片预览，后续须接带认证的受控视频加载。
- 基线静态检查退出码 0；素材、DB 与输出均计划置于上述私有根；日志绑定具体切片 diff / commit。
- 真实图库、实体 iPhone、iCloud 下载、付费模型、发布安装：全部 NOT_RUN。
- 后续扩展按目标第 10 节延期；未把必需失败项降格为技术债。
- 安全：未访问真实媒体、未源端写入、未外部传输、未停止其他进程。

## P1 第一切片验证（2026-09-27）

证据根 `/Volumes/SSD1/.codex-builds/video-completion-20260927/`；Web 绑定 `f84bff8b`（最终仅 lint 所需 String 转换和格式调整不改变行为）。

| 检查 | 命令概要 | 结果 | 日志 |
|---|---|---|---|
| 协议新旧媒体域 | `swift test --package-path Packages/ImageAllRemoteProtocol --scratch-path <证据根>/protocol --filter RemoteMediaContractTests` | PASS 1/1 | protocol-tests.log |
| 协议回归 | 同上去除 filter | PASS 73/73 | protocol-regression.log |
| Web 类型 | `npm run typecheck` | PASS | web-typecheck.log |
| Web 契约 | `npm run test:run -- src/api/contracts/mediaKind.test.ts src/api/contracts/asset.test.ts` | PASS 14/14 | web-contract-tests.log |
| Web 构建 | `npm run build` | PASS，产物仅网页 worktree | web-build.log |
| Web 实际解码／seek | `npm run test:e2e -- --project=chromium-desktop --workers=1 video-media.spec.ts` | PASS 1/1 | web-video-e2e.log |
| 照片浏览整理回归 | `npm run test:e2e -- --project=chromium-desktop --workers=1 gallery.spec.ts --grep 'gallery supports virtual browsing'` | PASS 1/1 | web-photo-regression.log |
| 改动文件 lint | `npx eslint <本切片 TS/TSX>` | PASS | web-lint.log |

浏览器素材由 ffmpeg testsrc2 生成 160×90 / 10 fps / 3 秒合成 MP4，只在本测试唯一临时根创建并清理；通过 mock Range 验证播放／拖动／关闭／切换及损坏、未知格式。此证据不能代替真实 Swift Host 浏览器联调。首轮 mock 未实现 Range 导致 seek 失败，修正后通过。Mac 首次构建在本轮 `mediaKind` 插入错误的另一个 DTO 调用处失败，已移到正确 mapDetail 后重跑；保留失败说明，不当作通过。

- Mac `xcodebuild -project ImageAll.xcodeproj -scheme ImageAll -configuration Debug -destination platform=macOS -derivedDataPath <证据根>/mac/DerivedData CONFIGURATION_BUILD_DIR=<证据根>/mac/Products OBJROOT=<证据根>/mac/Intermediates build-for-testing`：退出 0，TEST BUILD SUCCEEDED；`mac-build.log`。
- 直接 `xctest -XCTest ImageAllTests.RemoteCatalogFacadeTests/testFetchesPreviewInspectorDetailAggregateAndJobs,ImageAllTests.RemoteHTTPServerTests/testMediaRouteStreamsRealMIMEAndSingleByteRange`：退出 0，2/2；`host-contract-tests.log`。通过 DYLD_INSERT_LIBRARIES 加载私有构建 dylib，未启动生产 App 宿主。HTTP 测试使用唯一临时合成字节文件和 fake catalog；证明 MIME/Range，实际视频解码由浏览器合成测试单独证明。
- Mac 构建时主线由并行会话前进到 `27750a0788f3751610f400882c35c66b4da34942`；本轮 4 个受跟踪源码／测试文件差异仅 36 行新增，保存在 `p1-contract.diff`。构建含已有 OpenMontage 等工作树依赖，不宣称独立干净提交发布验收。
- 双工作区 `git diff --check` PASS。完整 P1 仍 IN_PROGRESS；尚缺 Mac/iPhone 播放整理闭环及必需 Web 集成。

## P1 Mac 播放器切片（实现与定向合成通过）

- 基于 `6cc5a6ca`；新增 `LibraryVideoViewer.swift`，系统播放／进度／音量／全屏控件和速度选择接入图库、审核、瘦身大图，保留系统播放器入口。空格在视频大图中控制播放／暂停，Esc 退出；照片路径保留。
- 本轮已独立提交 `83c5ceb1`；`LibraryWorkspace.swift` 和 `project.pbxproj` 含他人改动，启动副本保存在证据根 `p1-native-baseline/`，提交只取与该副本相比的本轮差异。
- 复用 `LibraryVideoPlaybackProviding`，默认不下载云端原件。请求身份隔离迟到资源，选择／来源／媒体域切换和关闭／失焦释放租约。新组件不把显示封面或播放器资源提升为去重证据。
- 合成测试文件 `LibraryVideoViewingTests.swift`：复用已登记 `synthetic-silent.mp4`；实际 AVPlayer 解码、seek、速度和音量、标签写入与数据库重开、照片人工事实回归、迟到请求、取消与损坏输入；Workspace 定向测试核对悬停互斥、视频大图标签动作与来源导航停止。
- 构建中曾遇 Swift IRGen 对 actor 方法 Binding 引用的编译器崩溃，改为显式闭包；测试 GRDB async write 缺 await 已修正。最终构建与 7 项定向测试均通过，见下列日志。
- P1 剩余：iPhone 受控认证播放、Web 必需主线集成、各端合成 UI／Host 联调证据；不把 Mac 局部播放器测试当完整 P1。

- 最终 `xcodebuild ... build-for-testing` 沿用 P1 的私有 DerivedData / Products / Intermediates，退出 0，`native-viewer-build.log` 的 TEST BUILD SUCCEEDED。
- `TMPDIR=<证据根>/test-tmp DYLD_INSERT_LIBRARIES=<私有 App>/Contents/MacOS/ImageAll.debug.dylib xctest -XCTest ImageAllTests.LibraryVideoViewingTests,ImageAllTests.LibraryWorkspaceModelTests/testVideoViewingKeepsTagActionsAndStopsOnSourceNavigation,ImageAllTests.LibraryWorkspaceModelTests/testVideoHoverStartsOnePlaybackAndReleasesItOnExit,ImageAllTests.LibraryWorkspaceModelTests/testSinglePhotoModeMovesPrimarySelectionAndReturnsToGrid,ImageAllTests.LibraryWorkspaceModelTests/testClosingLibrarySlimmingPreviewKeepsTheCurrentMemberSelected <私有 App>/Contents/PlugIns/ImageAllTests.xctest`：退出 0，7/7，`native-viewer-tests.log`。
- 新主路径包含合成目录 DB → 实际视频加载／seek → 标签 repository 写入 → 下一视频 → 重开数据库读取，照片已有人工决定保持不变；另一个模型测试证明视频大图保留标签动作、悬停互斥与来源导航停止。尚未以完整原生 UI 点击或真实图库验证，不能称原生端全验收。
- 构建及测试对应源文件摘要保存在 `p1-native-source-sha256.json`；`git diff --check` PASS。复用无声合成素材，未触及真实照片／视频或付费模型；未启动生产 Photos 宿主。

## P1 iPhone 认证视频播放切片（2026-09-27）

- 新增共享 `RemoteVideoPlayback` 与 iPhone `RemoteVideoPreviewView`。播放器使用不含凭据的私有 URL；请求通过已配对客户端发送 Bearer，复用证书绑定与禁止重定向策略。每次最多读取 256 KiB，无完整原件落盘缓存。系统预缓冲 10 秒只是提示，不宣称系统播放器总内存硬限额。
- Host 可选 `videoRangeStreamingVersion=1` 保持旧协议解码兼容；分段请求携带预期修订号，Host 返回修订头，双方校验。打开资源后再查 locator；版本变化返回 409，不向播放器拼接另一版本。
- 选择切换、关闭、后台与断连停止资源；同一资产同修订号的标签／收藏刷新保留播放器与进度。视频不进入照片预览预取路径；旧 Host、不可用原件、损坏响应和连接失败有明确提示，不自动下载 iCloud。
- `client-regression-final.log`：共享客户端 PASS 64/64，含视频 5 项。合成 MP4 通过 AVFoundation 实际解码、seek、停止；错误状态／修订／偏移／MIME、取消及超量响应拒绝通过。URLSession 流式实现还验证未声明长度的超量 body 会中止。
- `protocol-video-regression.log`：协议 PASS 73/73；`ios-video-build-final.log`：iOS Simulator 目标 BUILD SUCCEEDED。没有启动实体 iPhone 或生产 Photos 宿主。
- `revision-range-host-build-final.log`：Mac TEST BUILD SUCCEEDED；`revision-range-host-tests.log`：直接 XCTest PASS 2/2，含匹配修订 Range 206 和过期修订 409。客户端实际解码使用假 transport，Host HTTP 测试独立验证合成字节 Range；尚不构成 iPhone UI → 真实 Swift Host → 整理持久化的完整联调。
- P1 仍 IN_PROGRESS：必需 Web 主线集成、原生／iPhone 合成 UI 与 Host 联调未完成；P2–P7 尚未开始。

## P1 Web 源码主线集成（2026-09-27）

- 仅应用 `f84bff8b` 的 8 文件补丁，预检无冲突；未纳入长期 Web 分支的审核／地图／生成资源改动。源提交与 main 工作树逐字节相同，摘要见证据根 `web-main-source-parity.json`。
- main `WebCompanionApp` 执行 `npm run typecheck` PASS、`npm run test:run -- src/api/contracts/mediaKind.test.ts src/api/contracts/asset.test.ts` PASS 14/14；日志 `web-main-typecheck.log`、`web-main-contract-tests.log`。这些是集成后的类型与契约证据，浏览器解码证据仍绑定先前 Web 切片。
- 未在主工作区生成或覆盖网页资源。受当前网页产物隔离规则约束，生产资源更新与运行验收仍须单独安排；不以源码合入代替完整集成完成。
- iPhone 上轮本地提交 `90db409d`。下一切片补 Swift Host 与真实媒体客户端的隔离联调；P1 尚未达到完整退出标准。

## P1 实际 Host → 视频客户端联调（2026-09-27）

- Web 源码集成本地提交 `da2bf908`；源码已在 main，内置网页资源尚待处理。
- XCTest 测试目标单独链接 `ImageAllRemoteClient`，未改变生产 App 依赖；项目文件仅暂存本轮 13 行，保留已有 OpenMontage 的 4 行工作树改动。
- 新测试以 `RemoteHTTPServer` 回环监听、合成媒体 provider 和生产 URLSession 客户端，实际完成 HTTP 认证 → AVFoundation 解码 → 0.5 秒寻址 → 关闭释放，并验证错误修订和错误认证被拒绝。无 mock transport，无生产 composition root，无真实 Photos。
- `host-video-joint-build.log`：Mac TEST BUILD SUCCEEDED；`host-video-joint-tests.log`：新联调与原 Range 回归 PASS 2/2。直接 XCTest 命令沿用上一切片私有路径，选择 `testVideoClientDecodesAndSeeksThroughAuthenticatedSwiftHost` 与 `testMediaRouteStreamsRealMIMEAndSingleByteRange`。
- 此证据补上客户端与实际 Swift HTTP 服务的连接，不等于完整 iPhone UI／Web 浏览器 Host 联调；合成 provider 也不代替实际文件夹入库与 PhotoKit adapter 的证明。
- 下一动作：补 Web 实际 Host 浏览器证据与观看整理必要缺口；随后推进 P2 元数据。P1 总状态仍 IN_PROGRESS，目标仍 active。
