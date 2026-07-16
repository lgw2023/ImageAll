# ImageAll 阶段 2：Apple Photos 接入实施规格

> 状态：Slice A/B/C implemented and accepted<br>
> 日期：2026-07-17<br>
> 产品决策：项目所有者已批准“单图标准预览”作为 MVP 的显式 iCloud 获取方案<br>
> 文档基线：`3cb8853`；阶段 2 主要实现提交：`4f1e1a5`、`cd99bcb`、`eeb8cb4`、`7893f03`、`8aded93`、`1a4734c`、`5eca952`、`a474340`

## 1. 目标与本阶段位置

阶段 2 把当前 Mac 的 System Photo Library 作为单一 PhotoKit 来源接入现有三栏工作台：

```text
用户点击“连接 Apple Photos…”
→ 先阅读只读说明
→ macOS 照片权限请求
→ 静态照片元数据分批进入目录库
→ 本地可用缩略图渐进进入统一网格
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
- 一个 ImageAll 目录库最多维护一个当前 System Photo Library 来源；
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
- `PhotosLibraryConnectionPort`：读取授权状态、用户触发连接、重新授权和停用；
- `PhotosAssetSnapshotProviding`：返回稳定顺序的静态图片元数据批次；
- `PhotosImageProviding`：按 local identifier 请求本地限定 thumbnail / preview；
- `LibraryWorkspacePort` 增加 Photos 连接与按来源 kind 路由同步的用例。

SwiftUI、Domain 和通用目录查询不得导入 Photos。只有 `Infrastructure/Photos/` 导入 PhotoKit。

### 3.2 持久化与任务

Slice A 复用 v001 已有字段：

- `source.kind = photos`、`bookmark = NULL`、`sync_cursor`、`scan_generation`、`state`；
- `asset.locator_kind = photos`、`photos_local_identifier`、`file_name`、媒体元数据；
- `asset_current_photos_locator_uq` 保证同一来源当前 locator 唯一；
- `job` 保存 `photos.reconcile.v1` 任务、lease、checkpoint 和聚合进度。

本切片不新增 v005。单 Photos 来源由 Repository 事务与 UI 串行入口保证；若以后出现并发创建入口，
再用追加 migration 建立数据库级 singleton 约束，不回改 v001。

任务 payload 只保存 `source_id`。checkpoint 只保存 generation、下一批偏移和聚合计数，不保存 Photos
identifier。每批 Asset upsert、`last_seen_generation` 和 checkpoint 必须在同一 lease-protected 事务提交。
只有完整枚举成功后才把本 generation 未见的 Photos 资产标为 missing；中断不得推断批量删除。

### 3.3 图片请求

现有 `LibraryWorkspacePort.loadThumbnail/loadPreview` 保持来源无关。Infrastructure 先查询 Asset locator：

- file → 既有 `DerivedImageCacheService`；
- photos → 先查询已下载预览缓存；未命中时由 `PhotosImageProviding` 发起本地限定请求并编码为 UI 可读 Data；
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
暂停并要求确认、以及新旧图库的 Source 迁移属于未来独立切片，不能从本 Slice 的完成状态推断为已实现。

### Slice C：用户显式 iCloud 预览

状态：已按“单图标准预览”决策完成并验收。

- Inspector 单图“获取预览”；
- 单次请求的不透明下载能力；没有该能力时 adapter 不允许联网；
- `aspectFit`、长边最多 2048px 且不放大的标准预览，以及下载进度、取消、重试；
- 512 MiB LRU 下载预览子配额；条目仍计入统一派生缓存配额并受磁盘安全余量约束；
- 下载结果复用到预览、网格和个性化流水线；
- 首版不自动为全库建议任务下载 iCloud-only 内容，也不提供批量下载。

## 5. 阶段 2 最小 TDD 矩阵

按纵切片逐个红灯→绿灯，只验证公开行为：

1. 用户确认连接、授权成功后创建一个 active Photos 来源并入队一次 reconcile；再次连接复用同一来源；
2. 授权拒绝不创建 active 来源，Workspace 呈现安全失败；
3. 两批合成 Photo metadata 渐进入库，统一图库和 Photos 来源筛选均可查询；
4. video 被排除；Live Photo 只纳入静态主图；静态 JPEG/PNG/HEIC/TIFF/WebP 元数据保留；
5. 中断批次保留已提交项且不标记未见项 missing；完整 generation 才执行 missing 收敛；
6. Photos 资产缩略图走 local-only provider，file 资产仍走既有 Derived Image 路径；cloud-only 返回占位且
   测试证明没有 network-enabled 请求；
7. SwiftUI 模型证明连接入口触发 Photos 用例，成功后 Photos 来源与资产出现；
8. persistent change token 的增量应用、无效 token 全量回退、启动追赶和 observer 合并均不伪造 Asset 事实；
9. 显式单图下载证明只有该 2048px 请求启用网络，并覆盖进度、取消、重试、512 MiB 子配额 LRU 淘汰；
10. 下载结果无需再次读取 PhotoKit 即可生成 Feature Print、发布全库建议与 Review Queue，并刷新网格；
11. 相关 Catalog、Job、Workspace、Derived Image、Personalization 回归和 Debug build 通过。

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

本规格于 2026-07-16 以本机 macOS 26.5 SDK、deployment target macOS 15.0 核对：

- [Apple: Requesting Authorization to Access Photos](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app)
- [Apple: Fetching Assets](https://developer.apple.com/documentation/photokit/fetching-assets)
- [Apple: PHImageManager requestImage](https://developer.apple.com/documentation/photos/phimagemanager/requestimage(for:targetsize:contentmode:options:resulthandler:))
- [Apple: PHImageRequestOptions.isNetworkAccessAllowed](https://developer.apple.com/documentation/photos/phimagerequestoptions/isnetworkaccessallowed)
- [Apple: PHPersistentChangeToken](https://developer.apple.com/documentation/photokit/phpersistentchangetoken)
- [Apple: NSPhotoLibraryUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsphotolibraryusagedescription)
- [Apple: Photos Library Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.photos-library)

## 8. 阶段 2 验收记录

2026-07-17 已完成并验收阶段 2：

- Slice A 的连接与统一图库由 `4f1e1a5` 完成；Photos 个性化输入由 `cd99bcb` 接通；
- Slice B 的 persistent change history 与启动追赶由 `eeb8cb4`、`7893f03` 完成；
- Slice C 的单图标准预览及下游复用由 `8aded93`、`1a4734c`、`5eca952`、`a474340` 完成；
- `xcodebuild test -project ImageAll.xcodeproj -scheme ImageAll -destination 'platform=macOS,arch=arm64'`：
  761/761 通过，0 失败、0 跳过；
- `xcodebuild build -project ImageAll.xcodeproj -scheme ImageAll -configuration Debug -destination 'platform=macOS,arch=arm64'`：
  Debug build 通过；
- 构建产物包含批准的 `NSPhotoLibraryUsageDescription` 与 Photos Library entitlement；
- 静态审计未发现 Photos 写入/删除 API；生产代码只有显式单资产预览路径构造
  `isNetworkAccessAllowed = true`，其余图片请求保持本地限定；
- 自动化只使用 fake PhotoKit port 与临时数据库，没有请求真实 Photos 权限、访问 `/Volumes/HDD2` 或产生源端写入；
- `user/` 保持未跟踪，未 push。

发布前仍需由用户在专用或明确授权的 System Photo Library 上执行只读人工 smoke；该门不属于自动化，
也不授权访问受保护的真实照片路径。批量云下载和后台自动获取 iCloud-only 内容继续留在 MVP 范围外。
