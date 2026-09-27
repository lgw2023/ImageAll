# 视频能力补全推进记录

更新：2026-09-27。目标工具状态 active（用户续跑后已核验）；任务范围为目标提示词 P0–P7，不含第 10 节扩展。

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
| P2 | IN_PROGRESS | 首切片 PASS | 文件夹元数据、查询／地图／回填、原生云端获取及 PhotoKit 播放后技术信息持久化已分切片验；远端恢复提示、智能推流与完整 UI 待验 |
| P3 | IN_PROGRESS | 远端样本建议与媒体槽回归 PASS；完整持久审核链待验 | 继续全库建议、训练命令与审核持久事实闭环 |
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
| 视频时间／GPS／地图 | 文件夹视频内嵌时间／GPS 已提取并入库；地图 SQL 仍限 image | 依赖 Host，未验 | 依赖 Host，未验 |
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

## P2 文件夹视频时间／GPS 首切片（2026-09-27）

- 重排理由见媒体契约 ADR：P1 的资源集成／UI 验收保留，本切片不依赖它们，先形成视频元数据入库能力；未把 P1 标记完成。
- `FolderVideoMetadata` 新增可选位置；生产 AVFoundation 读取器提取明确时区的容器创建日期与 ISO 6709 十进制 GPS，经现有 reconcile 写入 `asset.media_created_at_ms` 与 `asset_location`，来源 `embeddedGPS`。无时区／缺失／非法字段保持未知，文件修改时间独立。
- 合成 AVAssetWriter MOV：`2026-09-27T00:30:00+08:00` 入库为上一 UTC 日，GPS 为 -33.8688 / 151.2093，90° 旋转后 48×64；唯一临时来源目录扫描前后快照一致。此切片未扫描真实目录。
- `video-metadata-build.log`：Mac TEST BUILD SUCCEEDED。直接 XCTest `ImageAllTests.FolderMediaClassificationTests`，`video-metadata-tests.log`：PASS 18/18，含真实合成 MOV → 生产分类 → reconcile → SQL 持久字段、无时区／非法坐标拒绝、视频资源释放及照片格式／GPS 回归。
- 测试和构建沿用证据根私有路径。源摘要 `p2-metadata-source-sha256.json`；`git diff --check` PASS。仅本轮读取器、分类测试、ADR 和本进度文件提交；不纳入并行改动。
- 下一具体动作：接入有界历史视频元数据回填与技术信息存储，然后完善视频条件／地图范围；P1 未验项继续保留。P3–P7 未开始，真实媒体／云端下载／真机／发布全部 NOT_RUN。

## P2 历史视频元数据版本与按需补读（2026-09-27）

- 发现上一切片对历史记录的实际缺口：旧视频指纹未变时复用旧观察，新增的时间／GPS 提取不会被调用。修复在已有扫描路径完成，入口为文件夹来源“立即重扫”，不另建批量扫描器。
- 新增 V053 `video_metadata_version`，旧资产默认 0；当前分类策略 1。版本不足时补读容器，完成后按指纹复用（缺失字段也不无限重读），记录随既有批次事务写入。元数据升级不递增内容修订号，已有位置／place_id 保留。
- 原扫描队列的分批、检查点、取消及恢复机制继续使用。版本 migration 本身不读媒体、不启动扫描。技术规格存储与地图回填范围还未完成，不能将此切片称为整个 P2 回填验收。
- 新增 V052→V053 合成升级测试，验证幂等及已有媒体时间／内容修订不变。扩展真实合成 MOV 入库测试，先退回旧版本和空元数据，再重扫恢复，最后验证当前版本复用及已有坐标保留。
- 第一轮编译修复了 throwing 短路表达式和异步测试缺 await。第一轮回归 74 项有 6 项失败：5 项为历史迁移回放夹具未剥离 V053，1 项为当前版本复用夹具仍使用默认版本 0；已分别修正夹具，最终 74/74 通过。

- 最终 `video-backfill-build-accepted.log`：TEST BUILD SUCCEEDED；`video-backfill-tests-final.log`：直接 XCTest 74/74 PASS（`FolderMediaClassificationTests`、`FolderReconcileLeaseMatrixTests`、`FolderReconcileTransactionTests`、`CatalogMigrationTests`）。复用私有 TMPDIR／构建路径，未启动生产测试宿主。
- 验证范围包括历史迁移回放、V053 幂等、合成视频旧策略补读与复用、原坐标保留、文件内容修订不变，以及现有中断恢复、取消、批次原子性。地图界面的混合媒体计数与单独回填按钮尚未完成，不能从这些测试推出其已可用。
- 证据源摘要 `p2-backfill-source-sha256.json`；`git diff --check` PASS。没有读取真实媒体、源端写入、云端请求或外部传输。下一步补技术信息存储／详情与视频查询条件，P1 未验项继续在原列表保留。

## P2 视频技术信息入库与跨端详情（2026-09-27）

- V054 新增可空技术信息 JSON；视频元数据策略版本升至 2，复用 V053 的按需补读机制。读取轨道 FourCC、标称帧率、估算码率、音轨数量，随既有批次原子入库并投影到 Inspector。旧 migration 未改写。
- Mac 信息面板展示四项；iPhone 与 Web 展示编码、标称帧率和音轨。DTO 字段可选，旧 Host 缺字段显示未知／尚未读取；文件格式、大小和时长沿用独立字段。标称帧率不当作恒定帧率，音轨数量不代表声音内容分析。
- Web 工作区提交 `cc90f69c`（3 个源码／契约测试文件），已只取本提交补丁集成 main，未夹带长期分支的审核、地图或生成资源。当前 Xcode 内置 Web 资源仍待集成，不能把源码集成称为完整 UI 交付。
- `video-technical-build.log`：Mac TEST BUILD SUCCEEDED；`video-technical-ios-build.log`：iOS Simulator BUILD SUCCEEDED。直接 XCTest `FolderMediaClassificationTests`、`FolderReconcileTransactionTests`、`CatalogMigrationTests` 和 Host 详情投影定向测试：`video-technical-tests.log` PASS 64/64。合成 H.264 MOV 的技术信息经过生产读取 → 数据库存储 → Inspector 查询，历史重扫与复用保持相同值；Host 投影测试检查可选字段。
- `video-technical-protocol-tests.log`：协议 74/74 PASS，含新字段往返与旧 Host 缺字段兼容。Web 独立工作区 typecheck / lint / build PASS、契约 15/15 PASS，日志 `video-technical-web-*.log`；main 集成后 typecheck 与契约再次验证，日志 `video-technical-main-*.log`。
- LibraryWorkspace 只暂存本轮信息区改动，保存启动副本和独立补丁；其余并行工作保持原样。源码摘要见 `p2-technical-source-sha256.json`。没有真实媒体读取、源端写入、云端获取或付费调用。
- 范围仍不完整：PhotoKit 技术信息提取、视频筛选／排序、混合地图范围、云端主动获取未完成；P1 的资源集成与 UI 验收继续保留。下一切片优先视频筛选与稳定分页，再接地图和 PhotoKit 差异。

## P2 原生视频筛选与时长／大小排序（2026-09-27）

- 新增共享目录查询条件：少于 1 分钟、1–10 分钟（不含 10）、10 分钟及以上，以及按已归一化宽高判断的横屏／竖屏／正方形。缺失元数据不命中相关条件。SQL 对视频条件显式限定媒体域，计数与分页共用条件构造。
- Mac 筛选菜单与排序菜单接入实际模型和查询；新增时长／文件大小双向排序，未知值后置，同值以资产 ID 稳定排序，使用独立 numericSort 游标。不同排序拒绝游标混用；筛选变化重载首屏，所有媒体域切换路径统一清除视频条件，照片不保留时长排序。
- `video-query-tests.log`：6/6 PASS，覆盖新查询的边界时长、三种方向、未知值、同大小、四种数值排序逐条分页，以及已有照片排序、时间排序、键集翻页、插入前项和游标错误回归。素材仅临时数据库记录，无源媒体读取。
- 首轮编译发现测试 fake 的游标 payload switch 需要处理新数值分支，已补齐；查询实现测试通过。最终模型状态测试与构建结果如下。
- 该切片为原生入口与目录层；Web／iPhone 尚未开放这些新条件与排序，Host 协议／能力声明待下一切片对齐。未以当前小型合成目录宣称大库排序性能，亦未完成地图与云端能力。

- `video-query-build-accepted.log`：Mac TEST BUILD SUCCEEDED；`video-query-model-tests.log`：`LibraryWorkspaceModelTests/testMediaKindSwitchDefaultsToPhotosAndClearsCrossPageSelection` PASS 1/1，验证模型向服务传递视频条件／排序、切回照片清除条件并恢复照片结果。直接 bundle 与私有 TMPDIR 沿用既有路径，未启动生产 Photos 宿主。
- 本轮原生 Workspace 以启动副本生成独立 staging 补丁，保留原有故事相关改动；源码摘要见 `p2-query-source-sha256.json`。`git diff --check` PASS。P1 未完成项继续保留，P2 下步推进远端查询契约与对应客户端入口，然后继续地图与 PhotoKit 差异。


## P2 Host 查询契约与 iPhone 控件（2026-09-27）

- 本轮 main 基线 `0a90fef0`；新增可选视频时长／方向请求字段与 `videoQueryVersion=1`，共享客户端编码 HTTP 参数，Host 严格校验并映射既有目录过滤和四种数值排序。旧请求继续可解码，旧 Host 不显示新控件，不静默忽略残留新条件。
- iPhone 筛选表单增加时长／方向，排序增加时长和大小双向；视频条件自动切到视频范围，切离视频清空相关条件。仅构建验证 UI，未宣称真机交互通过。
- `remote-video-query-ios.log`：iOS Simulator BUILD SUCCEEDED。`remote-video-query-mac.log`：Mac TEST BUILD SUCCEEDED。构建沿用证据根私有 DerivedData／Products／Intermediates，未替换或启动日常 App。
- `remote-video-query-protocol.log`：Swift package 75/75 PASS，含旧请求缺字段与新排序往返。`remote-video-query-client.log`：64/64 PASS，含实际 query 编码断言。
- `remote-video-query-host-tests.log`：直接 XCTest 2/2 PASS，选择 `RemoteCatalogFacadeTests/testMapsSourcesAndAssets` 和 `RemoteHTTPServerTests/testAssetRouteMapsAdvancedWebQueryFilters`；合成回环 HTTP 验证视频条件／大小排序到达 catalog，并拒绝未知时长、方向和排序。SQL 数值分页沿用上一切片已通过的独立测试，不把本轮 fake catalog 说成完整 DB 联调。
- 源文件摘要 `p2-remote-query-source-sha256.json`，`git diff --check` PASS。原有 LibraryWorkspace 75/5、项目文件与 OpenMontage 等并行差异保留；Web worktree 本轮只核对状态，没有修改或生成资源。
- 下一具体动作：在 `/Volumes/SSD1/ImageAll-Web-Dev` 补能力门控、视频条件／排序与必要浏览器请求验证，再以最小源码补丁集成 main。之后继续地图范围、PhotoKit 技术信息和显式云端获取；P1 的资源／UI 联调缺口仍保留，P3–P7 NOT_STARTED。
- 真实媒体、真机、iCloud、付费模型与发布安装仍 NOT_RUN；未访问受保护媒体、未源端写入、未外部传输、未 push。


## P2 Web 视频条件与源码集成（2026-09-27）

- Web 工作区 `lgw/imageall-web-dev` 本地提交 `1640279d`：时长／方向、时长及大小双向排序、Host 能力门控、URL 保留与选择缓存身份。切换照片清除视频条件；旧 Host 的带条件链接明确拒绝，不发送未筛选查询，并提供重置入口。
- 类型检查、改动文件 eslint、Web build 均 PASS，日志 `web-video-query-typecheck.log`、`web-video-query-lint.log`、`web-video-query-build.log`。生成资源仅位于 Web worktree。契约测试 `web-video-query-contracts.log` PASS 15/15。
- 浏览器 `video-query.spec.ts` 首轮 1/2：控件存在但 getByLabel exact 定位不匹配；改用实际 combobox 可访问名称，最终 `web-video-query-e2e-final.log` PASS 2/2。验证新条件请求、刷新保留、切回照片清除，以及旧 Host 零资产请求／重置恢复。此测试使用合成 HTTP mock，不是实际 Swift Host 浏览器联调。
- 既有照片浏览／范围选择／标签／撤销／收藏／详情回归 `web-video-query-photo-regression.log` PASS 1/1。
- main 仅应用此提交的 7 文件补丁，未合并长期 Web 分支或复制生成资源；`web-video-query-main-parity.json` 确认源文件逐字节一致，主线 typecheck 日志 `web-video-query-main-typecheck.log`。原生文件本轮未修改，既有 OpenMontage／Workspace 等并行差异保留。
- 新发现的必需缺口：分析跨页范围未包含时长／方向，本轮明确提示并阻止扩大范围，后续 P3/P4 分析切片补齐，不能视为完整分析闭环已实现。
- 下一具体动作：扩大地图可用视频与回填统计范围、保持媒体计数一致；再补 PhotoKit 技术信息／云端明确状态。P1 内置网页资源和实际跨端 UI 验收未完成；P2 IN_PROGRESS；P3–P7 NOT_STARTED。
- 未访问真实媒体、未源端写入、未云端下载、未外部传输、未 push；真机与生产发布仍 NOT_RUN。


## P2 地图共享媒体范围（2026-09-27）

- main 基线 `8fa9707d`。目录地图查询与点选查询新增可选 `mediaScope`，支持 photos / videos / all；历史缺字段默认照片。三条路径（聚合、点选、图库空间过滤）使用同一个固定枚举 SQL 条件，范围纳入缓存身份且在点选限量时保留。
- 位置回填 repository 的只读统计也支持显式范围，旧调用仍默认照片。尚未更改回填启动 controller、UI 或远端 DTO，不宣称视频地图用户闭环已完成；默认界面仍显示照片。计数旧属性名的解释与后续 UI 要求写入媒体契约 ADR。
- `map-video-scope-build.log` 首轮失败来自新增测试临时路径调用缺少 try；修复后 `map-video-scope-build-final.log` TEST BUILD SUCCEEDED。构建仍使用证据根私有目录。
- 首次直接 XCTest 误选 WorldMapSpikeTests，执行 0 项，不计通过。改为实际 WorldMapCatalogS1Tests 后，`map-video-scope-tests-final.log` PASS 8/8：新三域一致性、旧聚合、回收隐藏、点选限量、视口裁剪、反经线图库范围、回填只读统计、持久缓存恢复。
- 新合成 fixture 包含同地点照片／视频、无坐标视频和不可用视频；验证计数、cluster、selection、gallery ID 集合及照片／视频缓存隔离。未访问真实目录或启动 Photos 宿主。源摘要 `map-video-scope-source-sha256.json`；git diff --check PASS。
- 下一具体动作：原生地图范围选择器、数量单位与视频预览／图库跳转；将范围传到 Companion 协议；使视频来源回填启动条件与上述统计一致。P2 仍 IN_PROGRESS，不能以后台查询测试替代这些入口验收。
- 无真实媒体访问、源端写入、云端下载、外部传输或 push；既有 LibraryWorkspace 75/5、项目和 OpenMontage 并行差异保留。


## P2 原生地图入口与混合图库（2026-09-27）

- main 基线 `b3b2bf0b`。原生地图增加照片／视频／照片与视频选择器，媒体范围保存在地图导航状态中；切换时清除旧聚合、点选及预览并使旧请求失效。数量使用“项影像”，不再把视频数量标作张照片。
- 地图点选资产投影带 mediaKind / contentRevision；视频弹窗复用 LibraryVideoViewer，封面仍只读取缩略图，不自动播放。地图跳转图库保留空间和媒体范围；混合列表提供“仅照片／仅视频”缩小同一地点，横条明确显示媒体范围。单片播放空格键按实际选中资产媒体域判断。
- `map-video-native-build-accepted.log`：Mac TEST BUILD SUCCEEDED；`map-video-native-tests-final.log`：直接 XCTest PASS 5/5，包括 LibraryWorkspaceModelTests 地图导航、WorldMapCatalogS1Tests 三域查询投影、LibraryVideoViewingTests 三项播放生命周期／失败回归。播放器测试使用合成视频，不代表真实地图 UI 点击已验。
- 中间模型测试在旧照片断言处两次得到空列表。核查夹具发现 startsConnected 默认同时创建待扫描任务，start 后后台 reconcile 刷新会覆盖导航请求；纯导航夹具显式设置 hasPendingCatalogReconcileJobs=false 后重建并通过。生产扫描行为未改动，失败日志保留，不用重试结果冒充原轮通过。
- `map-ui-workspace.patch` 只暂存本轮 Workspace hunk，保留其既有 75/5 故事差异；源摘要 `map-video-native-source-sha256.json`；git diff --check PASS。已有项目／OpenMontage 改动未纳入。
- 下一动作：把地图范围传到 Host／Companion；接原生视频回填启动条件与统计／文案。混合范围的分析操作继续列为 P3/P4 必需核查，实际原生地图 UI 与 Web Swift Host 联调仍待验。P1、P2 IN_PROGRESS；P3–P7 NOT_STARTED。
- 未读取真实媒体、未启动生产 Photos 测试宿主、未源端写入／云端下载／外部传输／push；未发布或替换日常 App。


## P2 原生照片／视频位置回填（2026-09-27）

- main 基线 `33ea8185`。原生面板通过新增带 mediaScope 的 service 方法读取 all 统计，并以相同范围判断显式启动；仅含视频的来源不再被照片数为零误判为已完成。界面说明更新为照片与视频、ImageIO／AVFoundation／PhotoKit 路径，默认禁云端原件下载。
- 旧无参数 service／远端方法仍保持照片统计及启动语义。视频／混合范围未被悄悄塞入旧 DTO，后续由版本化远端地图契约对齐。取消仍按来源既有任务执行。
- 旧文件夹视频若仅有无坐标行且策略版本过旧，不计入已检查；已知 GPS 或当前策略的缺失结果计入已检查，避免无坐标视频反复回填。只读统计不打开媒体，实际执行继续沿既有扫描／原子批次路径。
- `video-backfill-ui-build.log`：Mac TEST BUILD SUCCEEDED；`video-backfill-ui-tests.log`：直接 XCTest PASS 6/6。覆盖仅视频来源旧策略排队、重复启动幂等、当前无 GPS 不重复回填、打开面板不扫描、照片统计、任务重试／取消和三种地图范围一致性。测试全部合成目录库，没有执行真实来源扫描。
- 源摘要 `video-backfill-ui-source-sha256.json`。Workspace 仅暂存独立 `video-backfill-ui-workspace.patch`，保留既有 75/5；git diff --check PASS。原生 UI 本身仍待合成运行验收，不把 model／repository 通过写成实际点击通过。
- 下一动作：Host／Companion 地图范围、聚合／点选／图库跳转和回填版本契约；之后继续 PhotoKit 技术信息与显式云端视频可用性。P1、P2 IN_PROGRESS；P3–P7 NOT_STARTED。未真实媒体读取、源端写入、云端下载、外部传输、push 或 App 替换。


## P2 远端地图范围查询契约（2026-09-27）

- main 基线 `813df44a`。新增可选 worldMapMediaScopeVersion=1 能力字段，地图聚合 GET 接收 mediaScope，点选 query 与响应 cluster selectionQuery 保留同一范围，图库空间 GET 使用 worldMapMediaScope；缺字段仍为照片，未知范围或孤立媒体范围参数明确拒绝。
- RemoteWorldMapAsset 新增可选 mediaKind。既有计数键保持兼容；新范围使用者必须以所选范围解释数量。回填接口尚未纳入本版本，旧远端回填仍为照片语义。
- 修复共享 RemoteLibraryClient 先前虽有 worldMapSelection DTO 却未发送其参数的问题：完整编码空间桶、视口边界、限量和媒体范围，防止地图进入图库范围丢失。
- `map-media-remote-protocol.log` PASS 76/76；`map-media-remote-client.log` PASS 64/64。`map-media-remote-build.log` Mac TEST BUILD SUCCEEDED；`map-media-remote-host-tests.log` 直接 XCTest PASS 3/3，涵盖 facade 的范围双向映射／资产媒体域、HTTP 地图路由和拒绝未知范围、图库空间范围映射与缺参拒绝。HTTP 测试使用合成 catalog，未宣称真实地图浏览器联调。
- `map-media-remote-source-sha256.json` 绑定本轮源文件；git diff --check PASS。Workspace 原有 75/5 和项目／OpenMontage 并行改动未变，未读取真实媒体、源端写入、云端下载、外部传输或 push。
- 下一动作：在独立 Web worktree 接能力门控、地图媒体选择、点选预览和图库 URL 范围传递；之后补远端混合回填，再继续 PhotoKit 技术信息与云端可用性。P1、P2 IN_PROGRESS，P3–P7 NOT_STARTED。


## P2 Web 地图媒体范围与主线集成（2026-09-27）

- main 基线 af3980d6。Web 工作区本地提交 8af6068e，补充数量单位提交 ba4caecb；地图可选照片／视频／混合范围，能力门控、URL 保留、点选到图库空间范围和详情上下文保持一致。旧 Host 保存链接不发送不受支持的地图请求，可切回照片恢复。
- web-map-media-typecheck.log、web-map-media-lint.log、web-map-media-build-final.log PASS；web-map-media-contracts.log 3/3 PASS。首次浏览器回归 4/5，发现改动误关闭默认照片地图的既有重试；恢复默认重试，仅对旧 Host 不支持范围禁重试，web-map-media-e2e-final.log 最终 5/5 PASS。全部使用合成 HTTP mock，非实际 Swift Host 浏览器联调。
- main 应用最小源码补丁，不合并长期 Web 分支、不复制生成资源。9 个 Web TS／测试文件与 Web 提交逐字节一致；共享地图 JS 的两分支原有基线不同，仅集成 7 处数量／影像文案，未宣称整文件字节相同。Web 既有该文件 38/8 改动保留。main typecheck PASS。
- 回填统计／命令尚未扩展到远端混合范围；P1 生成网页资源集成及跨端实际 UI 验收仍待做。P1、P2 IN_PROGRESS，P3–P7 NOT_STARTED。目标工具本轮实际查询为 paused，收尾后不自动开启下一切片。
- 未访问真实媒体、未源端写入、未云端下载、未外部传输、未 push、未替换 App；Workspace 原有 75/5 与 OpenMontage 并行改动保留。
- web-map-media-mac-build-final.log：Mac TEST BUILD SUCCEEDED；web-map-media-native-tests.log：直接 XCTest 1/1 PASS，合成 WKWebView 验证内置地图键盘切换、选中消息桥及“项影像”标签。没有启动生产 Photos 宿主；此窄回归不代表完整原生地图手工运行验收。git diff --check 与 JS 语法检查 PASS。


## P2 远端视频／混合位置回填（2026-09-27）

- 上轮属于 progress：主线 b9ed8e5c 已形成可验证源码提交。本轮从该基线继续，目标工具已恢复 active。原生 scoped service 接入远端统计及启动，新增 worldMapBackfillMediaScopeVersion=1、可选请求／结果范围，缺省兼容照片；幂等身份包含范围，异范围重复 operationID 明确 conflict。
- Web 工作区本地提交 45f4bd24：面板跟随地图媒体范围，按范围缓存，显式开始／取消保持范围，旧 Host 视频回填明确不可用。数量按当前媒体范围，任务进度标为来源扫描，打开面板不启动任务。5 个源码／测试文件最小补丁集成 main，生成资源仍只留 Web worktree。
- backfill-scope-protocol.log 76/76 PASS。Mac 首轮失败为新增默认实现引用错误枚举 CatalogQueryError.invalidQuery，改为既有 WorldMapCatalogError 后 backfill-scope-mac-final.log TEST BUILD SUCCEEDED。backfill-scope-host-tests.log 直接 XCTest 2/2 PASS，包含合成 HTTP GET／POST 范围传递、未知范围 400、默认兼容与异范围幂等冲突。
- Web 首轮夹具漏 capability 必填字段，修复后另发现合成 sourceID 不符合 UUID variant，均为夹具 schema 错误；修正后 backfill-scope-web-e2e-accepted.log 5/5 PASS（新回填 2 项与既有地图 3 项）。backfill-scope-web-build-accepted.log、backfill-scope-web-typecheck-final.log、backfill-scope-web-lint-accepted.log PASS。不以合成 HTTP mock 代替真实 Swift Host 浏览器联调。
- P1、P2 仍 IN_PROGRESS；P3–P7 NOT_STARTED。下一具体动作：PhotoKit 视频技术信息／云端资源明确状态与显式获取，再推进标签、AI、精确去重、多帧和混合故事主路径。地图地点标签解析仍为照片计数，纳入后续标签／地图对齐检查，不宣称地图全部语义均已完成。
- 未读取真实媒体、未执行真实来源回填、未云端下载、未源端写入、未外部传输、未 push 或替换 App。Workspace 原有 75/5、项目与 OpenMontage 并行改动均保留。
- main 类型检查 backfill-scope-main-typecheck.log PASS，Web 5/5 文件字节一致；源摘要 backfill-scope-source-sha256.json，git diff --check PASS。共享客户端旧 scratch 链接失败，符号为变更前 RemoteCapabilities 构造器；保留失败日志，使用全新 client-backfill-scope 构建目录后的 backfill-scope-client-final.log 64/64 PASS，证实源码兼容。


## P2 本地视频查看器技术信息（2026-09-27）

- 上轮为 progress：主线 e186784e 完成远端 scoped 回填，本轮先复核 PhotoKit 数据路径。PhotoKit 枚举已有日期／位置／时长，但不读取轨道规格；原视频请求默认本地、禁网络。既有 cloud preview 使用 requestImage，属于静态预览，不能当作视频原件获取。
- 共用原生查看器增加“视频信息”：从已取得的本地 AVAsset 异步读取 FourCC 编码、标称帧率、估算码率和音轨数。先让播放器就绪，技术信息失败不阻塞观看；加载中、失败及字段未知分开呈现。关闭／切换清除状态，并拒绝旧请求覆盖新资产。
- 这是播放资源观察入口，不是目录持久字段补齐；PhotoKit 技术信息持久化／远端详情、显式云端视频获取仍为必需缺口。本轮未改目录扫描、源端元数据或资产内容修订，未声明 P2 完成。
- 未读取真实 Photos、未触发云端下载、未外部传输、未启动生产 Photos 测试宿主、未 push／替换 App。仅修改原生查看器、对应既有合成测试及本目标记录；Workspace 原有 75/5 和 OpenMontage 并行差异保留，Web 工作区无新改动。
- viewer-technical-build-final.log：Mac TEST BUILD SUCCEEDED。viewer-technical-tests.log：直接 XCTest LibraryVideoViewingTests 3/3 PASS，复用本地合成 H.264 无音轨素材，验证编码 avc1、正帧率／码率、音轨 0、状态清理及原有 seek／标签持久事实／旧请求隔离／损坏视频失败回归。没有真实 PhotoKit 读取或新弹窗人工交互证据，不扩大该合成通过范围。
- git diff --check PASS，源摘要 viewer-technical-source-sha256.json。下一步仍是 PhotoKit 持久技术信息及显式云端视频获取，随后继续 P3–P7；目标保持 active，未将本轮查看器入口当作完整 P2。


## P2 原生显式获取云端视频（2026-09-27）

- 上轮为 progress：57cb3a78 提供本地播放资源技术信息。本轮基于该提交，把 cloudOnly 失败后的明确获取入口接到独立 grant-bearing PhotoKit 视频方法；普通本地请求仍禁网络。确认绑定当前资产／修订，允许一个前台获取请求，显示进度并可取消。
- 资源准备任务由 session 持有，关闭、切换、取消及后台停止会传递取消，迟到结果／进度按请求身份拒绝。后台恢复和普通重载不复用云端 grant。provider 在获取前后检查来源、定位符、媒体域、可用性和内容修订，禁用来源不能发起获取。
- 原件落盘及缓存由 Photos 系统管理，App 不另复制、不删除系统原件。UI 说明网络／空间成本、取消不等于清缓存。空间不足有明确恢复原因；PhotoKit 返回编辑合成 AVAsset 而非本地文件时明确说明限制及“照片”播放／导出文件恢复路径。未对未知原件大小或缓存卷做不可靠预估，不宣称 App 有固定字节配额。
- 本轮是原生共用查看器入口；Web／iPhone 显式云端视频能力仍需声明／恢复路线核对，静态 cloud preview 不算视频原件获取。PhotoKit 持久技术元数据与 Inspector 缺口仍在。P1、P2 IN_PROGRESS；P3–P7 NOT_STARTED。
- cloud-video-build-verified.log：最终 Mac TEST BUILD SUCCEEDED。cloud-video-tests.log：直接 XCTest 8/8 PASS（LibraryVideoViewingTests 5 项、PhotosIntegrationTests 3 项），覆盖显式 grant 网络策略、fake 下载／进度／取消／重试、禁用来源／请求前过期修订／返回后变化拒绝、PhotoKit 请求取消安装竞态、编辑合成资源明确拒绝和空间不足恢复原因。仍包含本地合成视频解码／seek／标签持久化回归。真实 iCloud 和 SwiftUI 确认弹窗人工验收 NOT_RUN。
- cloud-video-workspace.patch 仅暂存本轮 10 行 model 转接，原有 Workspace 75/5 保留；源摘要 cloud-video-source-sha256.json，git diff --check PASS。未访问受保护媒体、未源端写入、未实际云端下载、未外部传输、未 push／替换 App。
- 下一具体动作：补齐 PhotoKit 技术信息的按需持久化与 Inspector 刷新，核对远端云端视频能力提示；继续 P2 智能推流时间／位置语义并进入 P3。目标 active；不以本轮原生 fake 验收宣称 P1／P2 或整个目标完成。


## P2 PhotoKit 技术信息按需持久化与 Inspector 刷新（2026-09-27）

- 上轮为 progress：16218166 完成原生明确云端获取链路。本轮接通播放技术信息回调 → revision 条件写入 → 当前 Inspector 重读。仅当前可用 PhotoKit 视频／active 来源接受写入，不改 contentRevision 或标签。文件夹技术信息沿既有扫描路径，照片与历史资产不接收该写入。
- PhotoKit reconcile 内容变化时清空技术 JSON，未变时保留；既有 Host 详情投影读取同一字段，远端下次详情查询可见持久信息。仅在原生播放已获得的本地资源后补充，不触发额外网络、全库读取或批量回填；远端独立播放尚不触发这条原生观察回调，不宣称各端首次浏览都会补全。
- 原生云端能力的远端提示、P2 智能推流时间／位置证据与 P1 完整 UI／生成资源集成仍待核对；P1、P2 IN_PROGRESS，P3–P7 NOT_STARTED，目标 active。
- video-metadata-persist-build.log：Mac TEST BUILD SUCCEEDED。video-metadata-persist-tests.log：直接 XCTest 8/8 PASS，包括合成本地播放 → 条件写入 → Inspector 重读、内容修订和标签不变、旧修订／照片拒绝，PhotoKit 未变保留／变化清除，以及既有收藏写入不误增修订与播放／云端 fake 回归。没有真实 PhotoKit 或 Inspector 人工点击证据。
- video-metadata-workspace.patch 只暂存本轮 13 行 model 方法，原有 Workspace 75/5 保留；git diff --check PASS，源摘要 video-metadata-persist-source-sha256.json。未读取真实媒体、未源端写入、未额外云端获取／外部传输、未 push／替换 App；Web 工作区本轮无变更。
- 下一动作：远端云端视频状态与恢复提示，P2 智能推流跨媒体时间／位置范围核查，然后接 P3 已有视频 AI 的远端命令与审核链路。整体目标尚未达到完成条件。


## P2 远端云端视频状态与恢复提示（2026-09-27）

- 上轮为 progress：cef51719 交付 PhotoKit 播放后技术信息写回。本轮 Host 将云端视频原件缺失／不支持的编辑资源映射为兼容 404 加可选原因字段；共享客户端提供明确 Mac 获取／导出恢复说明，旧 Host 普通 404 仍可处理。
- Web 本地提交 5da99143：视频失败后最多 1 字节 Range 探测及 8 KiB 错误体解析，区分已知原因并允许重试播放。合成浏览器验证无静态 cloud-preview 请求、云端提示和恢复后实际解码／seek。仅 3 个源文件最小补丁集成 main，生成资源留在 Web worktree。
- media-reasons-protocol.log 76/76 PASS；media-reasons-client-final.log 65/65 PASS。media-reasons-mac-accepted.log Mac TEST BUILD SUCCEEDED，media-reasons-ios.log iOS Simulator BUILD SUCCEEDED。
- 首轮真实 Host 测试 1/2：生产 URLSession bounded transport 对所有非 2xx 返回空 Data，fake transport 未暴露此差异。修复为有界错误体读取，并补实际响应字段断言；media-reasons-host-tests-final.log 2/2 PASS（HTTP 原因传递、2 字节请求、正常解码／seek／授权／修订回归）。不将首轮失败记为通过。
- Web 首轮 lint 指出 while(true) 不必要条件，改为按 reader done 条件循环；media-reasons-web-lint-final.log、media-reasons-web-build-final.log、media-reasons-web-typecheck.log 及 main typecheck 均 PASS。media-reasons-web-e2e-final.log 1/1 PASS，包含播放、切换、云端失败、无预览下载和重试恢复的完整浏览器路径；使用合成 HTTP mock，非实际浏览器到 Swift Host UI 联调。
- Web 3 文件字节一致；源摘要 media-reasons-source-sha256.json，git diff --check PASS。原 Workspace 75/5 与 OpenMontage 等并行差异保留。未访问真实媒体、未云端获取／源端写入／外部传输、未 push／替换 App；真实 iPhone 和 iCloud 均 NOT_RUN。
- 下一具体动作：核对智能推流的视频时间／位置与跨媒体候选规则，继续 P3 远端视频 AI 命令／训练／审核。P1／P2 尚有完整 UI、资源集成与上述语义待验；目标 active，不能标记完成。


## P2/P3 智能推流媒体证据与优先级（2026-09-27）

- 上轮为 progress：cced5607 完成远端视频失败原因与恢复提示。本轮确认既有推流支持照片／视频混合候选，但排序硬编码照片模型并合并两类正样本计数，会掩盖视频模型和标注缺口。
- 排序改为核对候选涉及的每个媒体域；混合组各域都有模型才视为已覆盖，样本量取候选媒体域的最小正样本数。保留标签情境优先级、候选数量、时间及稳定 ID 排序。模型存在只用于排序，不代表模型质量已验收。ADR 已记录产品取舍。
- PhotoKit 时间／位置合成测试加入视频候选：已有时间与 GPS 证据可进入同源混合候选，缺 GPS 视频不被推测加入；候选仍保持 unknown，不自动接受或拒绝标签。既有忽略、确认、撤销及新决策保护继续通过。
- feed-media-build-final.log：Mac TEST BUILD SUCCEEDED。feed-media-tests.log：直接 XCTest ContextualTagFeedTests 8/8 PASS；涵盖照片模型不能覆盖视频、混合组补齐视频模型后的排序、时间／位置证据及既有事务回归。仅合成目录数据库，不代表真实 Photos 或智能推流 UI 手工验收。
- git diff --check PASS；源摘要 feed-media-source-sha256.json。Workspace 原有 75/5 与 OpenMontage 并行改动保留，Web 工作区本轮未修改。未读取真实媒体、未源端写入／云端获取／外部传输、未 push 或替换 App。
- P1／P2 仍 IN_PROGRESS，P3 主链路仍待推进，P4–P7 NOT_STARTED；目标 active。下一具体动作：追踪远端视频 AI 命令／训练的照片限定与原生视频采样、缓存及模型域契约，完成有验证依据的跨端能力对齐。


## P3 远端视频个人样本建议（2026-09-27）

- 上轮为 progress：76799745 修复智能推流跨媒体排序。本轮追踪至 AppPersonalSampleSuggestionRuntime，确认其使用 mediaKind 选择线性模型目录、发布记录和建议 capability；原生既有代表帧输入与远端 loadPreview 共用底层路径。
- 去除远端样本建议的照片限定，能力快照的视频个人建议模式改为 sample。取帧前后核对媒体类型、内容修订、active 来源与 available 状态；缓存仍绑定资产修订和完整编码器身份，未引入多帧缓存策略。标准外部服务／单资产建议／全库质心和 AdamW 命令仍需各自接通，不宣称全部远端 AI 已可用。
- 首轮直接 XCTest 54/55 PASS：旧来源筛选测试未提供匹配 Inspector 详情，被新修订检查拒绝；补齐候选 revision=3 的夹具。video-sample-build-accepted.log 最终 Mac TEST BUILD SUCCEEDED；video-sample-tests-final.log 最终 56/56 PASS（RemoteCatalogFacadeTests 55 项及照片／视频独立模型发布指针 1 项）。
- 新增视频样本命令测试验证媒体参数、一次 embedding、操作 ID 重放不重复计算、照片命令拒绝视频；建议运行时为 stub，仅证明调度与参数／重放，不作为真实模型打分、持久建议或完整审核链的证据。模型槽测试使用真实合成产物存储。P3 的样本→训练→建议→审核→撤销完整链仍为必需未验项。
- git diff --check PASS；源摘要 video-sample-source-sha256.json。Workspace 原有 75/5 及 OpenMontage 并行差异保留；本轮未改 Web，未读取真实媒体、未云端获取／源端写入／外部传输、未 push 或替换 App。
- P1／P2／P3 IN_PROGRESS，P4–P7 NOT_STARTED，目标 active。下一动作：接通有底层视频模型支持的全库质心／AdamW 建议命令，补一条真实合成目录持久建议到审核／撤销链，并核对训练、标准建议与客户端能力入口。


## P3 远端视频质心／AdamW 全库建议（2026-09-27）

- 上轮为 progress：7439ada8 开放远端视频个人样本建议。本轮核对 AppPersonalTagLibrarySuggestionRuntime 按 mediaKind／family／tagID 查发布产物，候选查询与执行已有媒体参数；去除按标签全库命令和可用性中的照片限定。
- 发布增加结果身份检查：模型媒体类型与命令一致、单标签身份一致、命中项属于本轮候选且分数有限。错媒体模型在激活／写入前失败。原有来源筛选、人工事实排除、方法最低分、样本上限与重放规则保留。
- 首轮 58 项测试中 3 个新增视频测试失败，原因为 review stub 的默认视频接口返回空标签／候选；补明确媒体接口后，video-tag-library-build-final.log Mac TEST BUILD SUCCEEDED；video-tag-library-tests-final.log 最终 58/58 PASS。新增质心／AdamW 视频调度与重放、错媒体模型发布拒绝，既有照片及远端事实回归通过。
- 本轮建议器与 review 为 stub，因此 insertedCount 只证明服务调用契约，不是数据库持久结果证据。完整合成模型／数据库建议 → Review → 人工事实 → 撤销，以及标准服务／单资产建议、训练与 Web／iPhone 入口仍待完成；不得以本轮绿色回归宣称 P3 完成。
- git diff --check PASS；video-tag-library-source-sha256.json 绑定源码。Workspace 原有 75/5 及项目／OpenMontage 并行差异保留；未修改 Web、未读真实媒体、未云端下载／源端写入／外部传输、未 push／替换 App。
- P1／P2／P3 IN_PROGRESS，P4–P7 NOT_STARTED，目标 active。下一具体动作：在真实合成目录和既有模型存储上验证视频个人建议持久化、审核与撤销，并继续剩余远端 AI 入口，不能再用 stub 发布计数替代完整链路证据。
