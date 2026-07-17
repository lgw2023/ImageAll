# ImageAll 阶段 2：Apple Photos 接入实施规格

> 状态：Slice A-G implementation and automated acceptance complete；受保护真实图库只读主路径 smoke 已完成；System Photo Library 切换/重绑定人工 smoke 仍开放<br>
> 日期：2026-07-17<br>
> 产品决策：项目所有者已批准“单图标准预览”，并选择保留旧 unavailable Source/Asset、为当前系统图库新建 active Source 的重绑定语义<br>
> 文档基线：`3cb8853`；阶段 2 主要实现提交：`4f1e1a5`、`cd99bcb`、`eeb8cb4`、`7893f03`、`8aded93`、`1a4734c`、`5eca952`、`a474340`、`2912022`、`3431439`、`9d7a2c2`、`dabb86e`

## 1. 目标与本阶段位置

阶段 2 把当前 Mac 的 System Photo Library 作为单一 active PhotoKit 来源接入现有三栏工作台：

```text
用户点击“连接 Apple Photos…”
→ 先阅读只读说明
→ macOS 照片权限请求
→ 静态照片元数据分批进入目录库
→ 本地可用缩略图渐进进入统一网格并持久化到应用派生缓存
→ PhotoKit 变化自动合并、执行 persistent history 对账并刷新工作台
→ 文件夹照片与 Photos 照片共用搜索、筛选、人工标签和 Review Queue
```

ImageAll 不导入、不移动、不编辑、不删除 Photos 资产，也不写入 Photos 关键词。Photos 来源只通过
PhotoKit 访问；`.photoslibrary` package 永远不是文件系统输入。

阶段 3 已先验证文件夹来源上的个性化建议闭环。本阶段只增加新的资产来源适配，不复制标签、搜索、
预测或 Review 业务规则。

## 2. 已批准产品行为

### 2.1 Sidebar 与统一图库

- “来源”下新增“连接 Apple Photos…”；未连接时不显示不可用占位来源；
- 连接后入口替换为带 Photos 图标的“Apple Photos”来源行；
- 选择该行只筛选此 Photos 来源；“全部照片”混合显示文件夹与 Photos 资产；
- 一个 ImageAll 目录库最多维护一个 active Photos Source；此前图库的 unavailable Source/Asset 作为历史事实保留；
- unavailable Photos 来源行标为“历史”，只有显式“连接当前系统图库…”并确认后才新建 active Source；
- 来源菜单使用“在图库中查看”“立即同步”“重新授权…”和“停用来源”；不提供删除照片或写回入口。
- 已连接的 Photos 来源返回零项时，空状态必须明确说明 ImageAll 只能访问 System Photo Library；
  不得把“当前在 Photos 中打开的其他图库”误报为格式不支持，并提醒更改 System Photo Library 可能影响
  iCloud Photos，须由用户自行确认。

### 2.2 授权时机与说明

- 只有用户点击“连接 Apple Photos…”后才展示 ImageAll 只读说明并请求系统权限；启动时不得主动弹窗；
- 说明明确：ImageAll 会读取照片及元数据，在自身容器保存索引、标签和派生缓存，不修改 Photos；
- 使用 `PHPhotoLibrary.requestAuthorization(for: .readWrite)`，因为持续 PhotoKit 读取使用该 access level；
  这不改变产品的源端零写入规则；
- `.authorized` 进入同步；`.denied` / `.restricted` 安全失败，不创建伪 active 来源；
- macOS 首版不建立 limited-library 产品语义；若未来 SDK/系统行为需要支持，再单独扩展。

### 2.3 媒体与 iCloud

- 首版纳入 `PHAssetMediaType.image` 中的支持格式；Live Photo 只读取静态主图，
  不读取或保存其视频伴随资源；视频资产仍排除；
- 目录库保存 PhotoKit local identifier、原始文件名、UTI、像素尺寸、创建/修改时间；不保存原图；
- 元数据枚举不触发内容下载；
- 默认缩略图、预览、Feature Print 和后台建议请求固定为本地限定；本地不可取得时显示云端占位，
  不自动下载；
- 本地可取得的 Photos 网格缩略图规范化为既有 `gridRegular` 派生变体并写入应用缓存；同一
  `asset_id + content_revision + representation_version + variant` 再次加载时不重新请求 PhotoKit，
  缓存损坏或事实版本变化时按既有校验与失效规则重建；
- 只有用户在 Inspector 对当前单个资产点击“获取预览”后，应用服务才签发该次请求的不透明能力，
  由 Photos Adapter 发起 `2_048 × 2_048` target、`aspectFit` 的联网请求；缓存标准预览长边最多
  2048px，不放大、不裁剪。调用方不能通过裸 `Bool` 开启网络；
- 显式请求支持进度、取消和失败后重试。成功结果写入 512 MiB LRU 下载预览子配额，并复用于
  Inspector、网格、Feature Print、全库建议和 Review Queue；该子配额仍计入统一派生缓存配额并受
  磁盘安全余量约束，缓存命中不会再次读取 PhotoKit；
- 批量云下载、后台自动下载 iCloud-only 资产和通用 job-scoped 下载授权不属于 MVP。

## 3. 技术边界与接口

### 3.1 Application 层

新增来源无关或 PhotoKit 隔离的公开契约：

- `LibrarySourceSummary.kind`：UI 根据 `.folder` / `.photos` 选择文案和动作；
- `PhotosLibraryConnectionPort`：读取授权状态、用户触发连接、重新授权、停用和显式重绑定；
- `PhotosAssetSnapshotProviding`：返回稳定顺序的静态图片元数据批次；
- `PhotosImageProviding`：按 local identifier 请求本地限定 thumbnail / preview；
- `PhotoThumbnailCachePort`：按来源无关 Asset ID 读取或发布 Photos 网格缩略图派生项；
- `LibraryWorkspacePort` 增加 Photos 连接与按来源 kind 路由同步的用例。

SwiftUI、Domain 和通用目录查询不得导入 Photos。只有 `Infrastructure/Photos/` 导入 PhotoKit。

### 3.2 持久化与任务

Slice A 复用 v001 已有字段：

- `source.kind = photos`、`bookmark = NULL`、`sync_cursor`、`scan_generation`、`state`；
- `asset.locator_kind = photos`、`photos_local_identifier`、`file_name`、媒体元数据；
- `asset_current_photos_locator_uq` 保证同一来源当前 locator 唯一；
- `job` 保存 `photos.reconcile.v1` 任务、lease、checkpoint 和聚合进度。

Slice G 不新增 migration。多个历史 unavailable Photos Source 可以共存；最多一个 active Photos Source 由
串行 GRDB 写事务和事务内二次检查保证，授权等待期间出现的竞争创建也必须安全失败。

任务 payload 只保存 `source_id`。checkpoint 只保存 generation、下一批偏移和聚合计数，不保存 Photos
identifier。每批 Asset upsert、`last_seen_generation` 和 checkpoint 必须在同一 lease-protected 事务提交。
只有完整枚举成功后才把本 generation 未见的 Photos 资产标为 missing；中断不得推断批量删除。

### 3.3 图片请求

现有 `LibraryWorkspacePort.loadThumbnail/loadPreview` 保持来源无关。Infrastructure 先查询 Asset locator：

- file → 既有 `DerivedImageCacheService`；
- photos → 先查询已下载预览缓存；网格请求再查询 `gridRegular` 派生缩略图；均未命中时由
  `PhotosImageProviding` 发起本地限定请求，成功字节经 `DerivedImageCacheService` 规范化并原子发布；
- 历史 Photos Asset 可以继续读取已登记的下载预览或网格缓存，但任何新的 local-only 或联网 PhotoKit
  请求都要求所属 Source 仍为 active，防止旧新图库相同 local identifier 串读；
- PhotoKit 报告 `PHImageResultIsInCloudKey` 且无本地图时，返回结构化 `cloudOnly`，UI 只显示云端占位；
- 不通过裸 `Bool` 暴露联网开关。

`downloadCloudPreview` 是独立的用户动作契约：只接受当前单个 Photos Asset，应用服务在调用 Photos Adapter
时签发单次不透明能力；只有该 adapter 路径构造 `isNetworkAccessAllowed = true`。成功字节经
`DerivedImageCacheService` 以 `aspectFit` 规范化为长边最多 2048px、且不放大的标准预览，落入 512 MiB
LRU 下载预览子配额；条目同时受统一派生缓存配额和磁盘安全余量约束。Feature Print 先查询该缓存，
未命中才尝试本地限定 PhotoKit 输入，因此全库建议不会隐式触发网络。

## 4. 实施切片

### Slice A：连接、全量元数据与本地缩略图

状态：已完成并验收。

交付：

1. Info usage description 与 Photos Library entitlement；
2. 用户触发的只读说明、授权和单 Photos 来源创建；
3. `photos.reconcile.v1` 的持久化分批全量枚举；
4. 静态图片 metadata upsert、完整 generation 后 missing 收敛；
5. 统一 Source 查询、Sidebar 行、来源筛选和“立即同步”；
6. 本地限定 grid / preview 图片请求和云端占位；
7. Composition Root 注册 Photos adapter 与 handler。

本切片原停止位置为 persistent change history、change observer、显式 iCloud 下载、Photos 来源切换检测
和真实个人图库自动 smoke；前三项已由 Slice B/C 收口。独立的 System Photo Library 身份检测/自动切换
恢复不在当前 MVP，真实图库验证仍保持只读人工门。

### Slice B：变化游标与来源恢复

状态：已完成并验收。

- 首次全量枚举前冻结 `currentChangeToken`，完成后重放变化再发布；
- 后续使用 `fetchPersistentChanges(since:)` 处理 inserted / updated / deleted local identifiers；
- token 安全归档到 `source.sync_cursor`，无效时回退到完整 generation；
- 权限撤销或图库 unavailable 时保留既有 Asset 事实与标签，不推断批量删除；
- 启动恢复与 PhotoKit change observer 只触发 reconcile，不直接写 Asset 事实。

当前实现不保存独立的照片库身份，因此不能自动区分 System Photo Library 切换与大规模合法变化；切换检测、
暂停已由 Slice F 完成，显式用户确认后的保守重绑定已由 Slice G 完成。该流程新建 Source，不声称新旧图库
同一，也不迁移、合并或删除旧事实。

### Slice C：用户显式 iCloud 预览

状态：已按“单图标准预览”决策完成并验收。

- Inspector 单图“获取预览”；
- 单次请求的不透明下载能力；没有该能力时 adapter 不允许联网；
- `aspectFit`、长边最多 2048px 且不放大的标准预览，以及下载进度、取消、重试；
- 512 MiB LRU 下载预览子配额；条目仍计入统一派生缓存配额并受磁盘安全余量约束；
- 下载结果复用到预览、网格和个性化流水线；
- 首版不自动为全库建议任务下载 iCloud-only 内容，也不提供批量下载。

### Slice D：PhotoKit 变化自动刷新

状态：已完成并验收。

- `PhotosLibraryChangeObserverCoordinator` 仍只在事务内递增 Photos 来源 `dirty_epoch` 并按既有 key 合并排队 `photos.reconcile.v1`，不直接写 Asset 事实；
- 事务成功且存在 active Photos 来源时，observer 启动追赶和后续变化通知同一个来源无关 Workspace runner；无 active 来源或事务失败时不通知；
- runner 自动消费 persistent change history，并刷新来源、统一网格、Review 状态及后续个性化调度；运行中和退出尾部到达的新通知复用既有重触发保护；
- Composition Root 不再提前静默启动 observer，而由 Workspace monitoring 生命周期统一启动；model 结束时同时停止 FSEvents 与 PhotoKit observer，stop 保持幂等。stop 会清除后续注册回调，但不是已捕获/在途 callback 的并发屏障；这类 callback 可完成事务，弱引用 model 通知和幂等 job 仍保证安全收敛；
- 本切片不改变 PhotoKit 读取/下载策略，不申请真实 Photos 权限，不读取真实图库，也不新增 schema、entitlement、privacy manifest 或依赖。

### Slice E：本地 Photos 网格缩略图持久缓存

状态：已完成并通过定向自动验收。

- `LibraryAssetImageLoader` 对 Photos 网格加载依次复用显式下载预览、`gridRegular` 派生缩略图，
  最后才请求 local-only PhotoKit；preview 行为保持不变；
- local-only PhotoKit 返回的网格字节经既有 ImageIO renderer 规范化后写入统一派生缓存，不保存原图，
  不启用网络，也不建立第二套缓存目录或数据库表；
- cache key 继续绑定 Asset ID、`content_revision`、representation version 和 variant；服务重建后可命中，
  损坏对象会先删除无效登记和对象，再由下一次本地请求重建；
- 写入失败、磁盘安全余量不足或缓存不适用时退化为本次内存结果，不把缩略图缓存故障升级为源端故障；
- 本切片不改变 512 MiB 显式下载预览子配额；Photos 网格缩略图只受统一派生缓存配额约束。

### Slice F：System Photo Library 切换时 fail-closed

状态：实现与合成自动验收已完成；真实 System Photo Library 切换人工 smoke 仍开放。

- `PhotoKitPhotosLibraryAdapter` 通过公开的 `PHPhotoLibraryAvailabilityObserver` 接收图库 unavailable 事件，
  并识别 `PHPhotosError.Code.switchingSystemPhotoLibrary`；其他 unavailable 原因同样按 fail-closed 处理；
- 事件事务把当前 active Photos Source 标为 `unavailable`，取消尚未运行的 Photos reconcile job，并向运行中
  job 写入 cancel 请求；事务成功后唤醒统一 Workspace runner，使来源和网格状态及时刷新；
- Source、Asset、标签、人工决定、同步游标和既有派生项全部保留，不把 unavailable 推断为批量删除或 missing；
- 普通 `connect()` 在读取授权前和创建/复用事务内都复核 unavailable 状态，不能因为授权状态变化或重复连接
  静默恢复旧 Source；恢复或绑定新图库必须进入未来的显式用户确认流程；
- full reconcile 的每个资产批次、最终 missing 收敛，以及 incremental reconcile 的最终提交，都在同一个
  lease-protected 事务中复核 Source 仍为 active；切换竞态会先回滚业务事实，再由 job 安全边界收敛为
  `cancelled`；
- 本次 PhotoKit 公开 API 核对未发现可持久化、可比较的稳定照片库身份。本切片因此不自动创建新 Source、不复用 local
  identifier 迁移旧 Asset、不删除旧 Source，也不声称能够判断切换前后是否为同一实体图库。

### Slice G：显式重绑定当前 System Photo Library

状态：已按项目所有者选择的 A 方案完成并通过合成自动验收；真实 System Photo Library 切换与重绑定人工
smoke 仍开放。

- 仅 unavailable Photos 来源提供“连接当前系统图库…”；确认文案明确旧索引、标签和历史继续保留，操作会
  新建来源，不合并或迁移资产，也不修改原照片；
- 重绑定在单一 GRDB 写事务中复核所选旧 Source 仍为 unavailable、当前不存在 active Photos Source，然后
  原子创建新 UUID Source 与一次 `photos.reconcile.v1` job；第二次重绑定或竞争创建安全失败；
- 普通 `connect()` 可以复用当前 active / authorizationRequired / disabled Photos Source，但仅剩历史
  unavailable Source 时必须在请求授权前失败；授权等待结束后仍在创建事务内复核，不能绕过显式确认；
- 旧 Source、Asset、标签、人工决定、游标与派生缓存不变；同一个 PhotoKit local identifier 在新旧 Source
  下仍由不同 Asset 事实承载；
- 新的 PhotoKit 图片读取只允许 active Source；历史缓存可读，但历史 Asset 不能用当前 System Photo Library
  的同名 local identifier 重新取图；Feature Print 与建议链路继续复用同一 active 判定和已下载缓存；
- 不新增 schema、entitlement、privacy manifest 或依赖，不自动判断新旧图库身份，不提供合并、迁移或删除。

## 5. 阶段 2 最小 TDD 矩阵

按纵切片逐个红灯→绿灯，只验证公开行为：

1. 用户确认连接、授权成功后创建一个 active Photos 来源并入队一次 reconcile；再次连接复用同一来源；
2. 授权拒绝不创建 active 来源，Workspace 呈现安全失败；
3. 两批合成 Photo metadata 渐进入库，统一图库和 Photos 来源筛选均可查询；
4. video 被排除；Live Photo 只纳入静态主图；静态 JPEG/PNG/HEIC/TIFF/WebP 元数据保留；
5. 中断批次保留已提交项且不标记未见项 missing；完整 generation 才执行 missing 收敛；
6. Photos 资产缩略图走 local-only provider 后持久化为 `gridRegular` 派生项，跨服务重建复用且损坏可失效
   重建；file 资产仍走既有 Derived Image 路径；cloud-only 返回占位且测试证明没有 network-enabled 请求；
7. SwiftUI 模型证明连接入口触发 Photos 用例，成功后 Photos 来源与资产出现；
8. persistent change token 的增量应用、无效 token 全量回退、启动追赶和 observer 合并均不伪造 Asset 事实；
9. 显式单图下载证明只有该 2048px 请求启用网络，并覆盖进度、取消、重试、512 MiB 子配额 LRU 淘汰；
10. 下载结果无需再次读取 PhotoKit 即可生成 Feature Print、发布全库建议与 Review Queue，并刷新网格；
11. observer 启动追赶与连续变化都会唤醒 Workspace runner，但仍只保留一个活跃 Photos job；无 active Photos 来源不通知，fake observer 在 stop 完成后新发事件不通知；不把 stop 断言成已在途 callback 的强屏障；
12. availability 事件原子暂停 active Photos Source、取消 reconcile 且不改 Asset 事实；重复连接不能恢复
    unavailable Source；全量枚举竞态不发布新资产也不把旧资产标为 missing；
13. 显式重绑定保留旧 Source/Asset/标签/人工决定，新建不同 active Source 和 reconcile job；相同 local
    identifier 按 Source 隔离，第二次重绑定与普通连接绕过确认均被拒绝；
14. 授权等待期间的竞争创建在事务内被复核；授权失败不会改写历史 unavailable Source；
15. 历史已缓存图片仍可读取，但缓存未命中时不能以当前 PhotoKit 解析历史 local identifier；
16. 相关 Catalog、Job、Workspace、Derived Image、Personalization 回归和 Debug build 通过。

测试只使用 fake PhotoKit ports、临时数据库和测试生成图片。自动化不得请求真实 Photos 权限、读取真实
图库、访问 `/Volumes/HDD2` 或遍历 `.photoslibrary`。

## 6. 安全、工程与 Git 门

- 生产 target 不得引用 `PHAssetChangeRequest`、`PHPhotoLibrary.performChanges`、资源写入或删除 API；
- entitlement 只增加 `com.apple.security.personal-information.photos-library = true`；
- Info usage 文案为“读取照片并在本地建立自定义标签和建议；ImageAll 不会修改或删除您的照片。”；
- 日志、错误和 Job payload/checkpoint 不记录 Photos local identifier；
- `user/` 保持未跟踪且不修改；不 push；
- Codex 实现 commit 使用 `feat(codex):` / `fix(codex):` 与 `Agent-Role: implementation`；
- 文档 commit 与可执行实现 commit 分开。

## 7. API 核对基线

本规格于 2026-07-16 至 2026-07-17 以本机 macOS 26.5 SDK、deployment target macOS 15.0 核对：

- [Apple: Requesting Authorization to Access Photos](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app)
- [Apple: Fetching Assets](https://developer.apple.com/documentation/photokit/fetching-assets)
- [Apple: PHImageManager requestImage](https://developer.apple.com/documentation/photos/phimagemanager/requestimage(for:targetsize:contentmode:options:resulthandler:))
- [Apple: PHImageRequestOptions.isNetworkAccessAllowed](https://developer.apple.com/documentation/photos/phimagerequestoptions/isnetworkaccessallowed)
- [Apple: PHPersistentChangeToken](https://developer.apple.com/documentation/photokit/phpersistentchangetoken)
- [Apple: PHPhotoLibraryAvailabilityObserver](https://developer.apple.com/documentation/photos/phphotolibraryavailabilityobserver)
- [Apple: PHPhotoLibrary.unavailabilityReason](https://developer.apple.com/documentation/photos/phphotolibrary/unavailabilityreason)
- [Apple: switchingSystemPhotoLibrary](https://developer.apple.com/documentation/photokit/phphotoserror/phphotoserrorswitchingsystemphotolibrary)
- [Apple: NSPhotoLibraryUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsphotolibraryusagedescription)
- [Apple: Photos Library Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.photos-library)

## 8. 阶段 2 验收记录

2026-07-17 已完成 Slice A-G 实现与各切片功能验收；全量性能绿色门已由 Stage 4-W 关闭：

- Slice A 的连接与统一图库由 `4f1e1a5` 完成；Photos 个性化输入由 `cd99bcb` 接通；
- Slice B 的 persistent change history 与启动追赶由 `eeb8cb4`、`7893f03` 完成；
- Slice C 的单图标准预览及下游复用由 `8aded93`、`1a4734c`、`5eca952`、`a474340` 完成；
- Slice D 的 PhotoKit observer 自动唤醒、统一 runner 与明确 stop 生命周期由 `2912022` 完成；
- Slice E 的 local-only Photos 网格缩略图持久缓存与跨服务复用由 `3431439` 完成；
- Slice F 的图库 unavailable 监听、Source/job fail-closed 与 reconcile 事务复核由 `9d7a2c2` 完成；
- Slice G 的显式确认、新 active Source、历史事实保留、竞争复核与跨图库图片读取隔离由 `dabb86e` 完成；
- Slice A-C 收口基线运行 `xcodebuild test -project ImageAll.xcodeproj -scheme ImageAll -destination 'platform=macOS,arch=arm64'`：761/761 通过，0 失败、0 跳过；
- 同一 Slice A-C 基线运行 `xcodebuild build -project ImageAll.xcodeproj -scheme ImageAll -configuration Debug -destination 'platform=macOS,arch=arm64'`：Debug build 通过；
- 构建产物包含批准的 `NSPhotoLibraryUsageDescription` 与 Photos Library entitlement；
- 静态审计未发现 Photos 写入/删除 API；生产代码只有显式单资产预览路径构造
  `isNetworkAccessAllowed = true`，其余图片请求保持本地限定；
- 自动化只使用 fake PhotoKit port 与临时数据库，没有请求真实 Photos 权限、访问 `/Volumes/HDD2` 或产生源端写入；
- `user/` 保持未跟踪，未 push。

Slice D 的 unsigned 全量结果为 796/796：`/tmp/ImageAll-Stage2D-20260717/Logs/Test/Test-ImageAll-2026.07.17_13-56-58-+0800.xcresult`；Apple Development 签名宿主 entitlement 1/1：`/tmp/ImageAll-Stage2D-20260717-signed-tests/Logs/Test/Test-ImageAll-2026.07.17_13-58-34-+0800.xcresult`。独立 bundle `/tmp/ImageAll-Stage2D-20260717-build/Build/Products/Debug/ImageAll.app` 使用 `com.gwlee.ImageAll.Stage2D.20260717`，通过 `codesign --verify --deep --strict`，批准 entitlement 未扩张。

Slice E 在只含 `3431439` 已提交内容的隔离副本中运行 `DerivedImageContractTests` 与
`PhotosIntegrationTests`，36/36 通过：`/tmp/ImageAll-Verify-3431439-20260717-1510.xcresult`。该结果是
定向自动验收。

Slice F 在只含 `9d7a2c2` 已提交内容的隔离副本中完成以下验证：

- `PhotosIntegrationTests` 21/21：`/tmp/ImageAll-Stage2F-PhotosAll-20260717-1620.xcresult`；
- Composition Root、Workspace 与 job 安全边界相关回归 50/50：
  `/tmp/ImageAll-Stage2F-Related-20260717-1625.xcresult`；
- Apple Development 签名 entitlement 1/1：
  `/tmp/ImageAll-Stage2F-SignedEntitlement-9d7a2c2-20260717-1650.xcresult`；
- arm64 Debug bundle 位于
  `/tmp/ImageAll-Stage2F-SignedBuild-DerivedData-9d7a2c2-20260717-1655/Build/Products/Debug/ImageAll.app`，
  bundle ID 为 `com.gwlee.ImageAll.Stage2F.20260717`，并通过 `codesign --verify --deep --strict`；实际
  entitlement 未超出批准项与 Debug 工具链注入的 `get-task-allow`。

同一提交的 unsigned 全量首次结果为 802 项中 799 通过、3 失败：
`/tmp/ImageAll-Stage2F-Full-9d7a2c2-20260717-1630.xcresult`。两个既有 runner 时序用例单独复跑 2/2
通过：`/tmp/ImageAll-Stage2F-RunnerRerun-9d7a2c2-20260717-1640.xcresult`；既有百万资产模糊搜索性能门
单独复跑仍以 8.628 秒超过 5 秒阈值，其中 search 查询为 8.372 秒：
`/tmp/ImageAll-Stage2F-QueryRerun-9d7a2c2-20260717-1642.xcresult`。本切片未修改 Catalog query、索引或
该测试，因此未为关闭 Photos 功能门而改写阈值；该历史性能门随后由 Stage 4-W 关闭。

Slice G 在只含 `dabb86e` 已提交内容的隔离副本中完成以下验证：

- Photos、Workspace、Composition Root、Feature Print 与全库建议相关回归 99/99：
  `/tmp/ImageAll-Verify-dabb86e-Targeted.xcresult`；
- Apple Development 签名 entitlement 1/1：
  `/tmp/ImageAll-Verify-dabb86e-SignedEntitlement-20260717-1552.xcresult`；
- arm64 Debug bundle 位于
  `/tmp/ImageAll-Verify-dabb86e-SignedBuild-DD-20260717-1552/Build/Products/Debug/ImageAll.app`，bundle ID 为
  `com.gwlee.ImageAll.Stage2G.20260717`，由 `Apple Development: 17621223203@163.com (CB9KZMUNYJ)`、Team
  `962554J6D3` 签名，并通过 `codesign --verify --deep --strict`；实际 entitlement 只有批准项和 Debug
  工具链注入的 `get-task-allow`；
- unsigned 全量 808 项中 807 通过，唯一失败是既有百万资产查询以 10.625 秒超过 5 秒阈值：
  `/tmp/ImageAll-Verify-dabb86e-Full.xcresult`；同一性能测试隔离复跑 1/1 通过，百万档六项累计 4.929 秒，
  其中线性 search 为 4.858 秒：`/tmp/ImageAll-Verify-dabb86e-Perf-20260717-1552.xcresult`。该结果贴近阈值且
  在全量并发环境退化，因此后续 Slice 保持原阈值并优化搜索。

Stage 4-W 由 `bea02c58934cf7e8ecd01b92100c868ef1f619b4` 关闭上述性能门。在只含该提交内容、
且不含 `user/` 的干净归档中，unsigned arm64 Debug tests 811/811 通过：
`/tmp/ImageAll-Verify-bea02c5-Full-20260717-1650.xcresult`。1 万档六项累计 0.012153125 秒，search
0.001453208 秒；100 万档六项累计 0.208921334 秒，search 0.128958917 秒。Apple Development
entitlement 1/1：`/tmp/ImageAll-Verify-bea02c5-SignedEntitlement-20260717-1722.xcresult`；独立 Debug
bundle 位于
`/tmp/ImageAll-Verify-bea02c5-SignedBuild-DD-20260717-1722/Build/Products/Debug/ImageAll.app`，通过
严格验签。该修复只改变本地目录库查询加速结构，不新增 PhotoKit I/O，也不改变 Stage 2 的来源隔离与
读取契约。

### 8.1 受保护真实图库只读主路径 smoke

2026-07-17 经项目所有者明确授权，使用精确 `df7bcc2` 干净归档构建的 Apple Development 签名 App，
只通过 PhotoKit 和应用 UI 完成只读主路径人工 smoke。验收事实如下：

- 独立 bundle `com.gwlee.ImageAll.Stage4Y.20260717` 由 Team `962554J6D3` 签名并通过
  `codesign --verify --deep --strict`；实际 entitlement 只有 App Sandbox、app-scope bookmark、
  user-selected read-write、Photos Library 与 Debug 工具链的 `get-task-allow`；
- 目录库最多一个 active Photos Source 的不变量成立；全量 reconcile 以 9518/9518 完成并发布
  9480 个可用静态图片资产；先前的 unavailable/失败历史事实未被覆盖或删除；
- 一个真实用户标签保留 2 个 accepted 与 2 个 rejected 人工决定，模型修订固化 4 个 positive 与
  4 个 negative 样本；全库建议复核时已推进到至少 1300/9480、生成至少 1315 个 Feature Print，
  并在 Review Queue 发布至少 406 条 `pendingReview` 建议；
- 建议任务在慢 Feature Print 批次内观察到租约剩余时间重新增长，证明 `76c6dca` 的半租约 heartbeat
  在真实 PhotoKit 工作负载生效；`79ea3b0` 与 `df7bcc2` 同样使 reconcile 在元数据枚举内续租并在
  pause/cancel 安全边界停止；`334ca5b` 保留用户已确认的建议启动意图；
- local-only Photos 网格缩略图路径曾生成 37 个 `gridRegular` 派生条目，并在 App 重启后命中复用；
  该数字只证明持久缓存路径和跨重启复用，不承诺条目绕过统一配额、磁盘余量或后续回收而永久驻留；
- `Personalization` 定向回归 27/27、`PhotosIntegrationTests` 28/28 通过。精确 `df7bcc2` 干净归档的
  unsigned 测试按互斥测试类分为四片，分别 204、203、186、222 项通过；签名 entitlement 面板另有
  4/4 通过，合计 819/819、0 失败。结果位于
  `/tmp/ImageAll-Verify-df7bcc2-20260717-1924/`；同一归档的独立 Debug App 构建和严格验签通过；
- 整个 smoke 未触发 iCloud 下载、未调用 Photos 写入 API、未直接访问或遍历 `/Volumes/HDD2` 受保护
  路径，也未读取仓库 `user/`；验收结束时 App 保持运行，让已确认的全库建议任务继续收敛。

本记录关闭连接、只读元数据对账、本地图片输入、个性化样本、Feature Print、全库建议与 Review Queue
可见结果组成的真实图库主路径门。三类代表性标签随后已按新的明确测试选择完成运行校准，混合质量结论与
停止位置见
[`STAGE-3-REVIEW-QUEUE-IMPLEMENTATION-SPEC.md`](./STAGE-3-REVIEW-QUEUE-IMPLEMENTATION-SPEC.md) 第 8.1 节。
该校准只记录当前本地轻量基线的能力边界，不要求现有相册标签预测达到统一准确率、样本完整性或
语义覆盖率，也不阻塞本阶段验收；后续通用语义预测模型另行评估。
System Photo Library 实际切换/显式重绑定仍是发布前人工门；批量云下载和后台自动获取 iCloud-only 内容
继续留在 MVP 范围外。
