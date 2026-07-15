# ImageAll 阶段 1 / 切片 4 Cursor 实施交接单

> 状态：Ready for implementation<br>
> 日期：2026-07-15<br>
> 实施者：Cursor CLI，仅 `Composer 2.5 Fast`<br>
> 产品与架构评审：Codex<br>
> 上一批准实现：阶段 1 / 切片 3 `main@bfa0cf0bcedd58ffbdc19dc163a065589f7aeb0d`<br>
> 上一 Codex 验收：`main@bd87fc5e91b110d62dda8c1706b8ce573ad48d72`<br>
> Cursor 开工 HEAD：由调用任务中的 `<LAUNCH_HEAD>` 替换为包含本交接单与任务留档的精确 Codex 文档 commit<br>
> 本轮唯一范围：`v003` 派生图缓存目录表、Image I/O 表示生成、配额/磁盘安全余量、损坏恢复与原子发布

## 1. 开工结论与停止位置

阶段 1 / 切片 3 已通过 Codex 终审：`folder.reconcile.v1` 对账闭环、严格媒体分类、lease-bound 资产批次和 generation 完成已获批准；基线为 499 项测试通过、arm64 Debug build 成功。切片 3 Cursor session 已退役。

本切片交付首个可被后续网格按需调用的派生图缓存后端，但不把它接到 SwiftUI、Composition Root、scheduler 或常驻 Job。实现必须用合成临时图片、临时缓存根和真实临时文件数据库证明：

1. `v003` 只新增一个 STRICT cache-entry 表和两个命名索引；
2. cache key 精确绑定 Asset、`content_revision`、representation version 与 variant；
3. Image I/O 正确处理方向、方形 aspect-fill、完整比例 preview、alpha 与编码验证；
4. 原图读取前后或目录库事实变化时不发布旧 revision 派生物；
5. 完整对象文件先原子发布，数据库 entry 后发布；崩溃最多留下孤儿文件，不留下指向半文件的 entry；
6. cache hit 的缺失、大小/hash 不符或不可解码只触发缓存重建，不改变 Asset 事实；
7. 20 GiB 配额和 `max(5 GiB, 目标卷容量 5%)` 安全余量在任何新写入前生效；
8. 淘汰和维护只能作用于 ImageAll 自有 Caches 派生根，来源端始终零写入。

完成后必须停止。不得接入 FSEvents、活动 projection、产品网格或任何 SwiftUI；不得新增 thumbnail Job、scheduler、timer 或后台循环；不得运行真实数据 smoke，或进入切片 5、6、7。

## 2. 开工门与文档优先级

Cursor 开工前必须按顺序完整读取：

1. [`AGENTS.md`](../AGENTS.md)；
2. 本交接单；
3. [`STAGE-1-IMPLEMENTATION-SPEC.md`](./STAGE-1-IMPLEMENTATION-SPEC.md)，重点第 1～3、5.3、6 节；
4. [`STAGE-1-BACKEND-ARCHITECTURE.md`](./STAGE-1-BACKEND-ARCHITECTURE.md)，重点第 3～4、7～8、11～13 节；
5. [`CURSOR-STAGE-1-SLICE-3-HANDOFF.md`](./CURSOR-STAGE-1-SLICE-3-HANDOFF.md)，只继承已批准的媒体、fingerprint、security scope 和只读语义；
6. [`LOCAL-TEST-DATA-SAFETY.md`](./LOCAL-TEST-DATA-SAFETY.md)；
7. 当前 `AppPaths`、migration、snapshot/startup、授权、Reconcile 与测试实现；
8. [`.cursor/rules/codex-review-handoff.mdc`](../.cursor/rules/codex-review-handoff.mdc)。

若本文与阶段规格或批准实现实质冲突，停止并报告，不得自行扩大范围或重解释产品语义。

开工必须证明：

- 使用全新 Cursor session，禁止 `--resume`、`--continue`、Cursor Task 子代理和 MCP；
- `system/init.model = Composer 2.5 Fast`；
- 当前为本地 `main`，HEAD 精确等于 `<LAUNCH_HEAD>`；
- 工作区除项目所有者已有未跟踪 `user/` 外无其他变化；不得读取、修改、暂存或提交 `user/`；
- 不得 reset、checkout、restore、stash、clean、amend、push 或改写历史；
- 不访问或遍历 `/Volumes/HDD2`，不读取真实 App 用户容器；测试路径必须由测试创建并登记。

## 3. 持久化边界：追加 v003

### 3.1 Migration ID 与历史

新增 migration ID 固定为：

```text
v003_add_derived_image_cache
```

`CatalogMigrationID.knownOrdered` 固定顺序变为 v001、v002、v003。`CatalogDatabase.makeMigrator()` 只在 v002 后注册 v003。

硬约束：

- `V001CreateCatalogCoreMigration.swift` 与 `V002AddStage1CatalogQuerySupportMigration.swift` 零字节修改；
- 不重建、不改列、不改索引、不改 DDL 文本，不给 `source`、`asset`、`file_fingerprint` 或 `job` 增列；
- v003 不创建 trigger、Job、settings、quota、FTS、prediction、Photos、undo 或 UI 状态表；
- snapshot、restore、future-schema 和 migration-prefix 逻辑只做 v003 所需的最小顺序更新。

### 3.2 STRICT 表：derived_image_cache_entry

表名固定为 `derived_image_cache_entry`，列与约束如下：

| 列 | SQLite 类型 | null | 精确语义 |
|---|---|---:|---|
| `id` | `TEXT` | 否 | PRIMARY KEY；与 v001 相同的小写 canonical UUID 结构与十六进制 CHECK |
| `asset_id` | `TEXT` | 否 | REFERENCES `asset(id) ON DELETE CASCADE` |
| `content_revision` | `INTEGER` | 否 | `>= 1`；生成时绑定的 Asset revision |
| `representation_version` | `INTEGER` | 否 | `>= 1`；本切片生产值固定为 1 |
| `variant` | `TEXT` | 否 | 只允许 `gridSmall`、`gridRegular`、`preview` |
| `storage_format` | `TEXT` | 否 | 只允许 `jpeg`、`png` |
| `pixel_width` | `INTEGER` | 否 | `> 0` |
| `pixel_height` | `INTEGER` | 否 | `> 0` |
| `byte_size` | `INTEGER` | 否 | `> 0` |
| `encoded_sha256` | `BLOB` | 否 | 精确 32 bytes；只校验派生文件，不回写 `file_fingerprint.sha256` |
| `created_at_ms` | `INTEGER` | 否 | `>= 0` |
| `last_accessed_at_ms` | `INTEGER` | 否 | `>= 0`；成功 cache hit 或首次发布时更新 |

表必须为 STRICT，并增加组合尺寸 CHECK：

- `gridSmall` 必须为 256×256；
- `gridRegular` 必须为 512×512；
- `preview` 的宽高都为正且 `max(pixel_width, pixel_height) <= 2048`；
- 任一 variant 不能借用另一 variant 的尺寸规则。

数据库不保存任意绝对路径、相对路径、扩展名、bookmark、来源文件名或用户输入路径。对象位置只由受校验的 entry UUID 与 `storage_format` 在 Infrastructure 内推导。

### 3.3 命名索引

只新增：

| 名称 | key | 语义 |
|---|---|---|
| `derived_image_cache_key_uq` | `asset_id, content_revision, representation_version, variant` | 同一 cache key 最多一个已发布 entry |
| `derived_image_cache_lru_idx` | `last_accessed_at_ms, id` | 稳定 LRU 淘汰顺序 |

`asset_id` 已是 unique key 首列，不再增加推测性重复索引。

## 4. Application 契约

生产命名可按现有风格微调，但 Application 层必须提供不含 GRDB、ImageIO、CoreGraphics、AppKit、security-scoped URL 或缓存路径的等价契约。

### 4.1 请求与返回

```text
DerivedImageVariant
  gridSmall | gridRegular | preview

DerivedImageRequest
  assetID
  variant

DerivedImagePayload
  entryID
  assetID
  contentRevision
  representationVersion = 1
  variant
  storageFormat = jpeg | png
  pixelWidth
  pixelHeight
  encodedBytes
  origin = cacheHit | generated
```

端口语义为异步 `loadOrGenerate`：命中有效缓存时返回 bytes；未命中、文件缺失或损坏时，在同一调用内保守重建。返回值不得暴露数据库行、SQL、绝对路径、bookmark 或 security-scoped URL。

另提供显式异步维护端口，返回且只返回聚合结果：

```text
DerivedImageMaintenanceResult
  removedEntries
  removedObjects
  removedBytes
  unsafeObjects
```

本切片不把这两个端口接到 App、View、Composition Root 或后台调度。

### 4.2 封闭安全错误

至少提供以下稳定 raw value；错误不得携带路径、文件名、bookmark、图片 bytes、SQL 或底层 NSError 文本：

| raw value | 语义 |
|---|---|
| `derivedAssetNotFound` | Asset 不存在 |
| `derivedAssetIneligible` | 非 current folder file、availability 非 available、metadata/fingerprint 不完整或格式不合格 |
| `derivedAuthorizationRequired` | 来源等待重新授权 |
| `derivedSourceUnavailable` | 来源暂时离线或不可访问 |
| `derivedSourceChanged` | 生成前后或最终发布前 source/revision/fingerprint 变化 |
| `derivedDecodeFailed` | 当前字节无法按批准静态图片解码 |
| `derivedEncodeFailed` | 派生表示编码或自校验失败 |
| `derivedCapacityUnavailable` | 无法取得可信的目标卷容量事实 |
| `derivedInsufficientSpace` | 配额或安全余量在淘汰后仍不足 |
| `derivedCacheUnsafePath` | 不能证明操作严格位于应用自有派生根 |
| `derivedCachePersistenceFailed` | 原子文件发布或 cache-entry 事务失败 |

缓存命中损坏不是 Asset 损坏事实；能重建时不向调用者暴露 `derivedDecodeFailed`，只有 source 本身此时也无法生成时才按实际 source/encode 错误失败。

## 5. 生成资格与 source 读取边界

生成输入必须在数据库读取时同时满足：

- Asset 存在，`locator_kind = file`、`locator_state = current`、`availability = available`；
- Source 存在，`kind = folder`、`state = active`；
- `relative_path` 与 `file_name` 继续满足批准规则；
- `content_revision >= 1`；
- `file_fingerprint` 存在，size 与 mtime 可用；
- media UTI 属于阶段 1 允许静态集合。

`disabled`、`unavailable`、`authorizationRequired`、`missing`、`unreadable`、`unsupported`、historical、Photos Asset 都不能生成新 entry。已有有效 entry 可以只按精确 cache key 返回；不得为状态变化伪造新 key 或改写 Asset。

复用切片 2～3 已批准的 bookmark 解析、stale 刷新、root validation、offline/authorizationRequired 分类和 scope start/stop 配对。生成器不得复制另一套权限状态机。

来源文件只能在已取得的 security scope 内以只读方式打开：

- 从已验证的相对路径逐分量解析，拒绝空、`.`、`..`、NUL 与根逃逸；
- 不跟随 symlink、Finder alias、package 或在扫描后被替换成链接的 locator；
- 生产 source 读取路径不得调用 create、write、truncate、remove、move、copy、rename、set resource values、sidecar 或 metadata 写 API；
- Image I/O 必须消费已经安全打开的只读数据提供者/句柄，不能在检查后再通过可被替换的未锚定路径重新打开；
- 自动化使用 source write spy 与前后树/bytes/mtime 对比证明零写入。

实现可以在 Infrastructure 内增加最小的 no-follow 读取 seam；不得把文件描述符或绝对 URL 暴露到 Application/Domain。

## 6. Representation version 1 渲染合同

本切片生产 `representation_version` 固定为 1；以下任一算法、尺寸、编码或颜色策略改变都必须递增版本，不能静默覆盖同一 key。

### 6.1 解码与方向

- 用 Image I/O 建立 source，并重新确认实际 canonical UTI 属于 JPEG、PNG、HEIC/HEIF、TIFF、WebP；
- 只接受恰好一个静态主图；动画或多帧输入不能因已有 `available` 行而被当成可生成；
- 使用 `CGImageSourceCreateThumbnailAtIndex` 等价路径，并启用“始终从主图生成”与方向 transform；
- orientation 1～8 都按视觉方向输出；测试使用非方形、非对称图像，不能只断言宽高；
- 解码失败不改变 Asset、fingerprint、revision 或 availability，等待下一次 reconcile 形成源事实。

Apple 官方说明 `kCGImageSourceCreateThumbnailWithTransform` 会按图片 orientation 与比例旋转/缩放缩略图；`CGImageSourceCreateThumbnailAtIndex` 必须显式指定创建缩略图选项：

- [Apple: CGImageSourceCreateThumbnailAtIndex](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex%28_%3A_%3A_%3A%29)
- [Apple: kCGImageSourceCreateThumbnailWithTransform](https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailwithtransform)

### 6.2 Variant 几何

| variant | version 1 输出 |
|---|---|
| `gridSmall` | 精确 256×256；按方向后的视觉图居中 aspect-fill，多余部分对称裁切；小图允许高质量放大以保证方形 |
| `gridRegular` | 精确 512×512；同上 |
| `preview` | 保持完整视觉比例，最长边不超过 2048；源图较小时不放大 |

渲染使用 8-bit sRGB。插值质量固定为高质量；不能依赖当前显示器色彩空间或 UI scale。

### 6.3 输出编码与隐私

- 解码图包含可能影响视觉结果的 alpha channel 时编码 PNG；
- 其余编码 baseline JPEG，quality 固定为 0.85；
- 输出只包含渲染像素和编码必需属性，不复制 EXIF、GPS、XMP、文件名、原始日期或其他来源 metadata；
- 编码到内存后先取得真实 `byte_size` 与 SHA-256，再写 staging；
- 发布前必须用 Image I/O 从编码 bytes 重新打开并验证：单图、storage format、预期像素尺寸、可完整解码、SHA-256 一致。

## 7. 缓存目录、路径安全与原子发布

### 7.1 应用自有根

派生根固定为：

```text
AppPaths.cachesDirectory/
└── DerivedImages/
    └── v1/
        ├── staging/
        └── objects/
            └── <entry UUID 去连字符后的前两位>/
                └── <小写 canonical entry UUID>.<jpg|png>
```

扩展名只由 `storage_format` 映射：`jpeg -> jpg`、`png -> png`。数据库不存路径。目录和对象名不能由 source 路径、文件名、Tag、用户搜索词或 bookmark 派生。

生产路径根只能来自 `AppPaths.cachesDirectory`；测试只能注入其当前测试登记的唯一临时根。创建/清理前必须证明：

- Caches 根与 `DerivedImages/v1` 均是预期的真实目录，且路径分量不是 symlink；
- 目标对象由合法 entry UUID、封闭 storage format 和固定 shard 规则推导；
- 操作严格锚定在打开的派生根，不通过字符串前缀比较或可被替换的绝对路径授权；
- 不跟随对象目录内的 symlink；不能证明安全时返回 `derivedCacheUnsafePath`，不得继续删除或发布。

生产删除/rename 应采用目录句柄相对、no-follow 的等价语义，消除“校验后路径被换成链接”的窗口。不得把 `/tmp`、Application Support、Backups、用户选择来源或其父目录作为缓存根。

### 7.2 发布顺序

单次生成固定顺序：

1. 在内存中完成渲染、编码和自校验；
2. 用唯一名称在 `staging` 中排他创建文件，完整写入并同步；
3. 从 staging 文件再次验证 size/hash/可解码性；
4. 同卷原子 rename 到全新 entry UUID 对象位置；目标已存在必须失败，不能覆盖；
5. 在一个 GRDB 写事务内重新验证 Asset current locator、Source 状态、`content_revision` 和 fingerprint，再替换该 cache key 的 entry；
6. 事务成功后才返回；旧 entry 对象在数据库不再引用后 best-effort 安全删除；
7. 任一步失败，删除本次可证明属于当前调用的 staging/final 对象；删除失败允许成为孤儿，不能发布指向半文件的行。

数据库 entry 永远后于完整对象发布。若进程在第 4 与第 5 步之间退出，只允许留下未引用对象；若第 5 步事务失败，新对象仍是孤儿。不得先插入 DB 再写/rename 文件。

Apple 建议 replacement 文件位于目标同卷，`FileManager.replaceItemAt` 的原子替换同样要求同卷；本设计使用全新 entry UUID 和同卷 rename，避免覆盖现有被引用对象：

- [Apple: FileManager replaceItemAt](https://developer.apple.com/documentation/foundation/filemanager/replaceitemat%28_%3Awithitemat%3Abackupitemname%3Aoptions%3A%29-4210g)

### 7.3 并发与 cache hit

- 同一 service 实例必须合并或串行化相同 cache key 的并发请求；
- 跨实例/进程竞争由 unique index 与最终事务防线解决：若事务中已出现另一份有效同 key entry，保留已发布 winner，删除本调用对象，不覆盖 winner；
- 最终始终只有一行、一个被引用对象；额外完整对象只能是可维护的孤儿；
- cache hit 必须安全读取推导对象，验证 regular/non-symlink、size、SHA-256、storage format、单图和像素尺寸；
- 有效 hit 更新 `last_accessed_at_ms` 并返回 `origin = cacheHit`；
- entry 缺文件或验证失败时，将该行视为不可返回的 replacement candidate，但不得在生成前单独提交删除；按当前 Asset key 重建，并在最终 GRDB 写事务内重新验证 candidate 与目录事实后原子替换；
- 若重建或最终事务失败，原无效 entry 可以暂时保留，但后续请求仍必须重新验证且绝不能把它当作有效 hit；新发布对象最多成为未引用孤儿。事务成功后，旧对象才 best-effort 安全删除；并发期间若另一份有效同 key entry 已获胜，则 loser 不覆盖 winner；
- 损坏、缺失与孤儿清理不得改 Asset、Source、fingerprint、Tag 或 Job。

## 8. Fingerprint 与 revision 稳定性

生成开始前：

1. 从目录库取得 cache key、current relative locator 与持久 fingerprint；
2. 在当前 scope 内安全打开 source；
3. 从打开对象取得 size、mtime 与 best-effort resource ID，必须与目录库快照相容；不相容即 `derivedSourceChanged`。

生成完成后、发布 entry 前：

1. 再从同一打开对象取得 fingerprint；
2. 再从 current locator 安全重开/探测，证明 locator 仍指向同一资源且 fingerprint 未变；
3. 在最终 GRDB 事务再次核对 Asset 仍 current/available、source active、relative locator、`content_revision` 与 `file_fingerprint` 均未变。

任一比较失败：

- 不发布 entry；
- 删除本调用 staging/final 派生物；
- 不更新 Asset、fingerprint、revision、generation、Job progress 或 availability；
- 返回 `derivedSourceChanged`，由后续 reconcile 负责形成新 revision。

`file_fingerprint.sha256` 继续保持扫描合同；本切片只 hash 自己编码的派生 bytes，不计算全库原图 SHA-256，不做去重。

## 9. 配额、磁盘安全余量与 LRU

### 9.1 固定策略

本切片不使用 UserDefaults、不增加配置 UI：

```text
published cache quota = 20 * 1024^3 bytes
reserve = max(5 * 1024^3 bytes, volumeTotalCapacity / 20)
representation version = 1
```

所有整数运算必须检查 overflow。单个编码结果大于配额直接返回 `derivedInsufficientSpace`。

### 9.2 容量 API

在派生根所在卷读取：

- `volumeAvailableCapacityForImportantUsageKey`；
- `volumeTotalCapacityKey`。

Apple 将前者定义为适合用户请求或 App 正常功能所需资源的可用容量查询，并要求在 privacy manifest 声明 required reason：

- [Apple: Checking Volume Storage Capacity](https://developer.apple.com/documentation/foundation/checking-volume-storage-capacity)
- [Apple: volumeAvailableCapacityForImportantUsageKey](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacityforimportantusagekey)

任一必需容量不可用、为负或计算溢出时 fail closed 为 `derivedCapacityUnavailable`，不得猜测无限空间。

### 9.3 Admission 与淘汰

编码 bytes 大小已知、任何 staging 写入前，按下列顺序：

1. 统计目录库已发布 entry 的 `byte_size` 总和；
2. 若 `publishedBytes + incomingBytes > 20 GiB`，按 `last_accessed_at_ms, id` 淘汰最老 entry；
3. 若 `availableBytes < reserve + incomingBytes`，继续按同一 LRU 淘汰，且每次实际删除后重新查询可用容量；
4. 淘汰先在事务中删除 entry，再安全删除其对象；只有对象实际删除才可用于容量回升判断，删除失败留下的孤儿由维护处理；
5. 无候选或全部淘汰后仍不满足时返回 `derivedInsufficientSpace`；
6. 满足两项 gate 后才允许 staging 写入。

不得淘汰目录库、snapshot、backup、runtime 文件、原图、bookmark、Source/Asset/Tag/Job 事实或派生根之外的任何对象。低空间错误必须通过 Application 结构化错误可观察，供切片 6～7 呈现。

20 GiB 是“已发布 entry”配额；单个进行中的 staging 对象不计入已发布量，但在安全余量中完整计入。孤儿不进入 DB 配额，必须由显式维护清理，实际卷容量 gate 仍会阻止其造成越界写入。

## 10. 显式缓存维护

本切片提供可直接测试、但不接 scheduler/启动流程的维护端口。单次维护在 cache service 的排他执行上下文中：

1. 校验自有派生根；
2. 读取全部 entry 的合法对象集合；
3. 对 entry 指向的缺失、非 regular、size/hash/格式/尺寸不符对象，删除 entry 后 best-effort 删除对象；
4. 删除没有 entry 引用的 `objects` regular file；
5. 删除不属于活跃调用的遗留 staging regular file；
6. 遇到 symlink、未知目录层级、无法证明归属或路径逃逸时不跟随、不触碰目标，计入 `unsafeObjects` 并返回安全结果或 `derivedCacheUnsafePath`；
7. 只返回聚合数量与 bytes，不返回对象名或路径。

维护必须幂等；第二次执行不再改变状态。Asset 删除级联 cache row 后留下的对象、发布事务前崩溃留下的对象和 DB 故障留下的对象都由此收敛。

## 11. Privacy manifest、权限与依赖

切片 4 首次使用 disk-space required-reason API，生产 App 的 `PrivacyInfo.xcprivacy` 必须精确包含：

```text
NSPrivacyAccessedAPICategoryFileTimestamp -> 3B52.1
NSPrivacyAccessedAPICategoryDiskSpace     -> E174.1
```

不得声明 UserDefaults、tracking、collected data 或其他类别。Apple 对 `E174.1` 的用途是：检查是否有足够空间写文件，或低空间时删除文件，并且 App 必须根据容量产生用户可观察的不同行为；本切片以结构化 low-space 结果建立后续 UI 所需状态：

- [Apple: NSPrivacyAccessedAPIType / Disk Space / E174.1](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [Apple: TN3183](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest)

entitlement 保持 sandbox、user-selected read-only 与 app-scope bookmark；Debug 可由工具链注入 `get-task-allow`。不得增加读写目录、Photos、网络、App Group 或其他 entitlement。

不得新增 Swift Package；继续使用系统 Foundation、ImageIO、CoreGraphics、CryptoKit 与现有 GRDB。

## 12. 强制 TDD 与验收矩阵

先按下列七簇各保留至少一个真实红灯摘要，再做最小实现。不得通过放宽断言、提前 return、条件 skip、只测 fake/helper、源代码文本 grep 代替运行行为或把不支持 fixture 静默算通过。

### 12.1 Migration 与 schema

- fresh DB 按 v001→v002→v003 各应用一次，重开幂等；
- 真实 v002 临时文件库带 Source/Asset/Tag/Job sentinel 升级后事实保留；
- unknown future migration 在 v003 前拒绝，业务表不被推进；
- 表为 STRICT；真实 `sqlite_schema`、`table_info`、`foreign_key_list`、`index_xinfo` 锁定全部列、CHECK、CASCADE 与两个索引；
- UUID、revision/version、variant、format、尺寸、byte size、hash storage class/长度、timestamp 全部正反例；
- cache key 重复拒绝，不同 revision/version/variant 允许共存；
- Asset 删除 cascade entry，Source RESTRICT 语义不变；
- v001/v002 原始 DDL、`Package.resolved` 和已批准 schema 零 diff；
- snapshot/create/restore、future-schema 与 startup migration-prefix 测试更新到 v003，旧 snapshot 的合法前缀升级仍收敛。

### 12.2 Application 契约与资格

- variant/raw error vocabulary 封闭，payload 不含路径；
- current available folder 正例；不存在、historical、Photos、missing/unreadable/unsupported、四类非 active Source 与 fingerprint 缺失反例；
- exact key hit；revision、representation version 和 variant 任一变化都 miss；
- scope success、cache hit、source change、decode/encode/DB failure 全部严格 start/stop 配对；
- Application/Domain 无 GRDB/ImageIO/CoreGraphics/AppKit/CoreServices import，无 URL/路径泄漏。

### 12.3 Image I/O 与视觉结果

- JPEG、PNG、HEIC、HEIF、TIFF、WebP 的小型静态输入能生成；不得 skip；
- orientation 1～8 用非对称像素 fixture 验证视觉方向；
- gridSmall/gridRegular 精确尺寸、居中 crop 与小图放大；preview 横/竖/方图的比例、2048 上限和不放大小图；
- alpha 输入输出 PNG 并保留透明像素；opaque 输入输出 JPEG，quality/version 合同固定；
- 输出统一 sRGB、可重新解码、单图、SHA/size 与 DB 一致；
- 输出不包含 EXIF/GPS/XMP/原文件名/原时间 metadata；
- 动画/多帧、运行中损坏或实际 UTI 漂移结构化失败，不发布 entry。

### 12.4 Fingerprint、命中与并发

- 生成前 stored 与 current fingerprint 不一致，无 staging/entry；
- 解码期间替换、mtime/size/resource ID 任一变化，临时对象丢弃；
- final DB 事务前 revision、locator、availability、Source 状态或 fingerprint 变化，零 entry；
- 同 revision 有效 hit 不再次打开 source/解码，touch LRU；
- cache 文件缺失、截断、同尺寸篡改、格式/尺寸错误均删除 entry 并重建，不改 Asset；
- 同 key 并发请求最终一行、一个被引用对象，所有返回 bytes 一致；竞争 loser 不覆盖 winner；
- content revision 增加后旧 entry 不命中，新 entry 独立发布。

### 12.5 原子发布与 fault matrix

对生产 adapter 的每个真实 fault seam 执行，而非只安装未触发：

- staging 排他创建、写中断、同步、staging 自校验失败；
- final rename 失败；
- final 已发布但 DB transaction 开始前中断；
- DB insert/update、final asset revalidation、LRU touch 后段失败；
- 替换旧 key entry 的事务失败；
- 旧对象删除失败；
- 第 4 步前失败无对象/无 entry；第 4 步后失败最多孤儿、绝无 entry 指向半文件；
- maintenance 能清理各类孤儿，重复运行幂等；
- 重开真实临时文件库后有效 entry 可读。

故障断言必须比较完整、稳定排序的 Asset/fingerprint/cache-entry 事实与缓存树，而非只比较行数。

### 12.6 配额、容量、LRU 与路径安全

- 20 GiB、5 GiB、5% 与恰好等于/差 1 byte/overflow 边界；
- capacity unavailable/negative fail closed，staging 未创建；
- published+incoming 超配额按 `last_accessed_at_ms, id` 稳定淘汰；
- 可用容量不足时淘汰后重新查询；足够则发布，不足则无新 entry；
- 单对象大于配额拒绝；
- 淘汰只删 entry 和对应自有对象，不改任何事实表或来源；
- cache root、staging、objects、shard 或 object 被 symlink 替换时拒绝跟随；
- 非法 UUID/format、未知目录层级、祖先/外部路径、`/tmp`、Application Support、Backups 与 source 根均不能成为删除目标；
- Asset cascade 孤儿、发布孤儿、staging 孤儿、缺失 entry、损坏 entry 的维护聚合和二次幂等；
- 维护结果不泄漏对象名或路径。

### 12.7 Privacy、只读与回归

- built App 内 `PrivacyInfo.xcprivacy` 可解析，且精确只有 FileTimestamp/`3B52.1` 与 DiskSpace/`E174.1`；
- 源码与 built manifest 一致；不用 UserDefaults；
- built entitlements 无变化，Executable 仍 arm64，macOS target 仍 15.0，Swift language mode 仍 6；
- source write spy 为零；临时来源前后树、bytes、mtime 与关键 metadata 相同；写入只出现在当前测试登记的 Caches 根和临时 DB；
- 既有 499 项测试全部回归，新增测试全部通过，Debug build 成功；
- App/SwiftUI、RootView、Composition Root、scheme、产品外观、`foundationReady/CatalogReady` 语义零修改；
- 无 `/Volumes/HDD2` I/O、无真实 App 容器 I/O、无 `user/` 读取或提交。

## 13. 明确禁止

- 修改 SwiftUI、`ImageAll/App`、RootView、Composition Root、Sidebar、网格、Inspector、菜单、活动入口或任何外观；
- 接入 FSEvents、Source/Job 活动 projection、scheduler、timer、后台 loop、新 Job kind 或常驻处理器；
- 修改 v001/v002、已发布产品/标签/对账语义，或提前进入切片 5～7；
- PhotoKit、Vision/Core ML、OCR、AI、网络、全库原图 SHA-256、跨来源去重；
- 写 source、创建 sidecar/隐藏文件、修改来源 metadata；
- UserDefaults、配额设置 UI、新 entitlement、新 package；
- 访问 `/Volumes/HDD2`、真实 App 容器或 `user/`；
- 修改 Codex 文档或 `docs/cursor-cli-tasks/`；
- push、amend、reset、checkout、restore、stash、clean、rebase、cherry-pick、squash 或 history rewrite。

若必须违反任何一项才能通过，停止并提交架构差异，不得用占位、跳过或越界代码绕过。

## 14. 验收、提交与交回

必须运行：

```bash
xcodebuild -scheme ImageAll -destination 'platform=macOS,arch=arm64' \
  -configuration Debug -resultBundlePath /tmp/ImageAll-stage1-slice4.xcresult test

xcodebuild -scheme ImageAll -destination 'platform=macOS,arch=arm64' \
  -configuration Debug build

git diff --check
```

还必须报告：

- 从新 `xcresult` 独立取得准确 passed/failed/skipped，总数不得只引用旧基线；
- `plutil` 验证 built PrivacyInfo 的两个类别与唯一原因；
- `codesign` 实际 entitlement；
- build settings 中 Swift 6、macOS 15.0、`ARCHS` 未写死且当前 executable 为 arm64；
- v001/v002、`Package.resolved`、App/SwiftUI、Composition Root、scheme、entitlement 的精确零 diff；
- 生产依赖方向、缓存根安全静态检查和 source write spy；
- 七簇红灯→绿灯摘要、fault 实际触发点、配额/容量边界和维护幂等；
- `/Volumes/HDD2`、真实 App 容器与 `user/` 零访问。

创建一个窄范围本地 commit：

- author/committer：`Cursor Agent <cursoragent@cursor.com>`；
- subject：`feat(cursor): add derived image cache`；
- trailer：`Agent-Role: implementation`；
- 不含 `Co-authored-by`；
- 不提交 docs 或 `user/`，不 push。

交付后工作区除既有 `?? user/` 外必须干净，并按 [`.cursor/rules/codex-review-handoff.mdc`](../.cursor/rules/codex-review-handoff.mdc) 输出中文复审材料。明确停止于切片 4，未进入 FSEvents/活动投影或切片 6～7 UI。

## 15. Codex 重点复审点

1. v003 是否只有一个 STRICT 表和两个索引，且 v001/v002 原始 DDL 真正零修改；
2. entry 后于完整对象发布、并发 winner 与 fault 路径是否保证绝无半文件引用；
3. Image I/O 的 orientation、crop/fit、alpha、sRGB、metadata stripping 是否由像素级测试证明；
4. pre/post source 与 final DB revalidation 是否真实阻止旧 revision 发布；
5. 20 GiB、5 GiB/5%、LRU、DiskSpace manifest 与 fail-closed 是否精确；
6. 删除/维护是否以自有根锚定且 no-follow，不能触及来源、祖先或外部路径；
7. 是否严格停在后端端口，未修改 App/SwiftUI、未新增 Job/watcher/scheduler。
