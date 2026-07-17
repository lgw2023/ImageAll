# ImageAll 阶段 4：可恢复发布纵切片实施规格

> 状态：Core implementation complete；Slice W 百万资产搜索性能余量已关闭
>
> 决策日期：2026-07-17
>
> 权威范围：可移植用户数据导出、预览缓存维护、持久任务活动控制
>
> 开工基线：`641afb34990fcc141332eff861874cbfea43e77e`

## 1. 目标与顺序

阶段 4 先完成三个不依赖真实照片的产品闭环：

1. Slice J：版本化 JSONL 数据包与 manifest；
2. Slice K：预览缓存用量与安全清理；
3. Slice L：活动任务列表与暂停、继续、取消。

顺序固定为“先保护不可重建事实，再提供存储维护出口，最后暴露已有持久任务控制面”。三个切片
均使用合成目录库和临时目录自动验证，不读取 `user/`，不访问或遍历 `/Volumes/HDD2` 受保护数据，
不调用 Photos 写入 API，不 push。

## 2. Slice J：可移植 JSONL 用户数据导出

### 2.1 用户流程

用户从图库工具栏选择“导出用户数据…”，在系统面板选择父目录。应用在该目录生成一个
`ImageAll-Export-<UTC timestamp>/` 数据包；成功后显示数据包名称和导出记录数，取消不显示错误，
失败显示不泄漏路径或底层数据库信息的安全提示。MVP 不提供导入、覆盖已有数据包或自动上传。
系统面板授予的 security-scoped 写权限只在本次导出期间使用并及时释放，不持久化新的 bookmark。
导出未加密，包含用户标签、相对路径和 Photos local identifier；界面必须提醒用户选择可信位置，
操作系统或第三方可能继续同步用户选择的云目录。

导出父目录必须与全部已记录文件夹来源隔离。应用在建立临时目录前解析并只读开启每个来源 bookmark；
父目录与来源相同、位于来源内或包含来源时拒绝，目录库查询、bookmark 解析、安全作用域开启或目录关系
任一无法确定时也保守拒绝。只有全部来源均可证明不重叠时才进入导出器。production target 为这次用户
选择的导出位置保留 app-wide `user-selected.read-write`，但来源 bookmark 继续显式使用
`.securityScopeAllowOnlyReadAccess`，不能据此写入原图来源树。

### 2.2 数据包格式

数据包格式固定为 `imageall-portable-export` version `1`，UTF-8 JSONL 每行一个 JSON 对象，字段名
使用 snake_case，文件末尾保留换行。UUID 是小写规范字符串；时间是 Unix epoch 的有符号 64 位
毫秒整数，只有 `modified_at_ns` 使用纳秒；SHA-256 是 64 字符（256 位）小写十六进制字符串；枚举使用下表列出的
持久 raw value。可空键始终存在并写为 JSON `null`。字段按名称排序，记录按稳定主键升序写出。
“稳定”只承诺同一目录库事实的数据文件字段与记录顺序稳定；manifest 的建立时间不同，因此两次完整
数据包不承诺逐字节相同。

数据包包含：

| 文件 | 内容 | 稳定顺序 |
|---|---|---|
| `sources.jsonl` | Source ID、种类、显示名、状态和记录时间 | `id` |
| `assets.jsonl` | Source 关联、文件相对路径或 Photos local identifier、媒体元数据、内容 revision、可用性 | `id` |
| `file_fingerprints.jsonl` | 文件大小、mtime 与已有 SHA-256；不含 resource identifier | `asset_id` |
| `tags.jsonl` | 标签 ID、名称、归一化名称、状态和记录时间 | `id` |
| `decisions.jsonl` | 资产、标签、人工接受/拒绝和更新时间 | `asset_id, tag_id` |
| `tag_models.jsonl` | 标签当前模型 revision 与更新时间 | `tag_id` |
| `model_revisions.jsonl` | provider、特征版本、阈值、样本预算和建立时间 | `tag_id, revision` |
| `model_samples.jsonl` | revision 的资产关联、内容 revision、正负角色、rank 与特征版本 | `tag_id, model_revision, role, rank, asset_id` |
| `manifest.json` | 格式、版本、建立时间、目录库 migration、逐文件记录数、字节数和 SHA-256 | 文件名升序 |

JSONL v1 精确字段如下，除标有 `null` 的值外都必填：

| 文件 | 字段与 JSON 类型 |
|---|---|
| `sources.jsonl` | `id:string`, `kind:string(folder\|photos)`, `display_name:string`, `state:string(active\|disabled\|unavailable\|authorizationRequired)`, `created_at_ms:integer`, `updated_at_ms:integer` |
| `assets.jsonl` | `id:string`, `source_id:string`, `locator_kind:string(file\|photos)`, `relative_path:string|null`, `photos_local_identifier:string|null`, `locator_state:string(current\|historical)`, `file_name:string|null`, `media_type:string`, `width:integer|null`, `height:integer|null`, `media_created_at_ms:integer|null`, `media_modified_at_ms:integer|null`, `content_revision:integer`, `availability:string(available\|missing\|unreadable\|unsupported)`, `record_created_at_ms:integer`, `record_updated_at_ms:integer` |
| `file_fingerprints.jsonl` | `asset_id:string`, `size_bytes:integer`, `modified_at_ns:integer`, `sha256:string|null` |
| `tags.jsonl` | `id:string`, `name:string`, `normalized_name:string`, `state:string(active\|archived)`, `created_at_ms:integer`, `updated_at_ms:integer` |
| `decisions.jsonl` | `asset_id:string`, `tag_id:string`, `decision:string(accepted\|rejected)`, `updated_at_ms:integer` |
| `tag_models.jsonl` | `tag_id:string`, `current_revision:integer`, `updated_at_ms:integer` |
| `model_revisions.jsonl` | `tag_id:string`, `revision:integer`, `provider:string`, `request_revision:integer`, `preprocessing_revision:integer`, `threshold:number`, `positive_count:integer`, `negative_count:integer`, `neighbor_count:integer`, `sample_budget_per_role:integer`, `created_at_ms:integer` |
| `model_samples.jsonl` | `tag_id:string`, `model_revision:integer`, `asset_id:string`, `content_revision:integer`, `role:string(positive\|negative)`, `rank:integer`, `provider:string`, `request_revision:integer`, `preprocessing_revision:integer` |

`manifest.json` 精确包含 `format:string`、`format_version:integer`、`created_at_ms:integer`、
`app_version:string`、`applied_migrations:[string]` 和 `files:[object]`。每个 file object 含
`filename:string`、`record_count:integer`、`byte_count:integer`、`sha256:string`；`files` 只列上述八个
JSONL，不列 manifest 自身，避免递归校验。

导出明确排除 bookmark、sync cursor、resource identifier、原图字节、缩略图、下载预览、Feature
Print 向量与 cache key、prediction、Job payload/checkpoint/lease/错误、日志和任何绝对路径。Photos local
identifier 仅用于同一 System Photo Library 的最佳努力重连，不承诺跨设备恢复。

v1 导出全部当前已持久化的模型 revision 与代表样本元数据。`metrics`、`selection_policy` 和
`evaluation_assignment` 尚未进入当前 v004 schema，且三个真实标签 evaluation cohort 仍延期；它们
不是被判定为可丢弃，而是当前不存在可导出的事实。以后新增这些不可重建字段时必须同步演进导出格式，
不能继续生成遗漏事实的 v1 数据包。

### 2.3 一致性与发布

- 在一个 SQLite 一致性读事务中按游标流式写出全部 JSONL，不把全库记录加载进内存；
- 先在用户所选父目录内建立隐藏的唯一临时同级目录，完整写入并关闭所有文件；
- 重新读取每个文件，验证 JSONL 可逐行解码、记录数、字节数和 SHA-256，再写入并验证 manifest；
- 只有全部验证通过才把临时目录在同一父目录内重命名为最终数据包；目标冲突直接失败，不覆盖；
  MVP 只承诺支持同卷原子 rename 的目标文件系统，不宣称跨卷发布或断电耐久性；
- 任何失败都尽力移除本次临时目录，不能留下看似成功的最终数据包；
- 导出只读目录库，不取得来源授权，不读取原图或 PhotoKit。

### 2.4 最小测试门

1. 合成目录库同时含 folder 与 Photos 资产、标签、决定和模型元数据时，导出稳定且 manifest 的记录数、
   字节数和 SHA-256 全部匹配；
2. 数据包中不存在注入的 bookmark、sync cursor、resource identifier、绝对根路径、Job secret、
   cache key 或 prediction secret；
3. 写入或发布故障不会产生最终数据包，并清理本次临时目录；已有同名目标不被覆盖；
4. Workspace 用户动作呈现成功、取消和安全失败结果；
5. 相关测试、完整 arm64 Debug tests、Debug build 与 `git diff --check` 通过。

### 2.5 停止位置

Slice J 不实现导入、增量导出、压缩、加密、云同步、XMP/sidecar、原图打包或跨设备 Photos 重连。

## 3. Slice K：预览缓存用量与安全清理

### 3.1 用户流程与范围

工具栏提供“缓存”面板，显示持久预览缓存的条目数和已登记字节数。用户选择“清理预览缓存”后
必须确认；成功后用量刷新为零，已显示网格不清空，后续缩略图和单图预览按需重建。

本 Slice 只管理 `derived_image_cache_entry` 及其 `Caches/ImageAll/DerivedImages/v1` 对象与 staging。
它不删除 Feature Print、模型 revision/sample、人工决定、prediction、Job、来源或资产，不修改用户原图。
这样避免把模型训练元数据生命周期偷偷并入一次普通缓存清理。
清理已下载的 iCloud-only 预览后，用户必须对该单图再次显式执行“获取预览”；后台不会无感重下载。

### 3.2 原子性与并发

- 用量来自目录库登记事实，字节总和使用溢出安全聚合；面板可额外报告孤儿对象数，但不把目录遍历
  当作主用量事实；
- 清理与单项 cache hit、发布、淘汰共用现有维护互斥边界；清理期间新生成请求等待或安全失败，不能
  创建指向已删除文件的登记；
- 在修改登记前先完成 version root、objects、staging 的路径类型和未知项安全预检；遇到符号链接或未知
  目录项时整体拒绝，登记保持不变；
- 预检通过后先删除登记并提交，再删除对应应用生成对象；文件删除失败可留下可回收孤儿，不能恢复
  已经无效的登记；此时结果为“缓存已失效，部分空间待回收”，面板登记用量为零但不宣称磁盘已释放；
- 只在固定 cache version root 下操作应用生成的相对路径；符号链接、未知目录项或越界路径必须拒绝；
- staging 仅清理由 ImageAll 命名的普通文件，不跟随链接。

### 3.3 最小测试门

1. 用量准确聚合 grid、preview 和已下载预览登记；
2. 清理后登记为零、登记对象被删除，人工事实和 Feature/model/prediction/Job 行逐项保持；
3. 符号链接或删除故障不越界、不删除外部 sentinel，目录库不留下悬空登记；
4. Workspace 确认动作呈现成功或安全失败，并刷新用量；
5. 相关测试、完整 arm64 Debug tests、Debug build 与 `git diff --check` 通过。

### 3.4 停止位置

Slice K 不提供配额调整、按来源/类型清理、Feature Print 清理、自动定时清理或 Finder 路径展示。

## 4. Slice L：活动任务与产品级控制

### 4.1 用户流程

工具栏“活动”面板列出最多 100 个最近任务，活动任务优先，其后按更新时间倒序。每行显示安全的
任务名称、状态、进度和可用动作；不得显示 payload、checkpoint、lease owner、底层路径、Photos
identifier 或原始错误消息。

MVP 任务名称只映射现有 `folder.reconcile.v1`、`photos.reconcile.v1` 和
`personalization.fullLibrarySuggestions` kind；界面分别显示“文件夹同步”“Apple Photos 同步”和
“个性化建议”。未知 kind 显示“后台任务”，不能暴露原始 kind。状态与动作遵循既有 Job 状态机：

- pending：暂停、取消；
- running：请求暂停、请求取消；请求落库后立即显示“正在暂停”或“正在取消”；
- paused：继续、取消；
- retryableFailed：取消；重试仍由既有调度策略决定；
- completed、terminalFailed、cancelled：只读。

继续只创建 `paused → pending` 的既有状态转换；终态不可复活。列表刷新和控制命令都通过
Application Port，不让 SwiftUI 直接访问 GRDB。

活动集合固定为 pending、running、paused、retryableFailed。查询排序为
`active_rank ASC, updated_at_ms DESC, id ASC LIMIT 100`，因此超过 100 个活动任务时只显示其中最近更新
的 100 个。进度只投影 `progress_completed` 和可空 `progress_total`：total 存在时显示
`completed / total`，否则只显示 completed，不猜测百分比。

running 的 pause 已登记后禁用重复 pause，但仍允许升级为 cancel；cancel 已登记后所有动作禁用，
不能被 pause 降级。控制命令失败时重新查询并显示数据库当前事实，再给出安全提示，不能把调用前状态
当作仍然有效。状态控制优先级固定为 `none < pause < cancel`。

### 4.2 最小测试门

1. 查询只投影安全字段，排序、100 条上限、kind 安全文案和进度均稳定；
2. pending/running/paused/retryableFailed/terminal 的动作矩阵与既有状态机一致；
3. running pause/cancel 的持久 control request 可见，cancel 不被后续 pause 降级；
4. Workspace 动作成功后刷新对应行；失败命令不额外改变任务，并重新查询、展示数据库当前事实和
   安全提示；
5. 相关测试、完整 arm64 Debug tests、Debug build 与 `git diff --check` 通过。

### 4.3 停止位置

Slice L 不增加新 scheduler、自动轮询守护进程、终态重试、批量控制、通知中心或 App 退出后继续运行。

## 5. 阶段停止位置

首批 J/K/L 三个切片通过后，阶段 4 仍未宣称完整完成。10 万合成元数据基准已经按第 6 节关闭，
1 万独立查询基线
与 100 万查询门已经按第 7 节关闭，100 万可移植导出已经按第 8 节关闭，缓存清理压力门已经按第 9 节
关闭，发布前隐私/故障回归已经按第 10 节关闭，100 个有效 JPEG 可丢弃 fixture 的扫描—查询—缩略图
生成—缓存命中基线已经按第 11 节关闭，六种受支持静态格式的并发冷/热图片 I/O 基线已经按第 12 节
关闭，导出目标与全部文件夹来源的隔离门已经按第 13 节关闭，两类导出隔离故障的可操作提示已经按
第 14 节关闭，独立沙盒中使用合成临时文件夹的真实 `NSOpenPanel` 权限、bookmark 跨重启无面板重扫、
100 张合成图片的 SwiftUI 网格滚动、单图标准预览和导出交互已经按第 15 节关闭，百万资产搜索性能余量
已经按第 16 节关闭；百万级 v005→v006 迁移耗时与峰值工作副本空间、三个真实标签校准、Apple Photos
权限回归、真实摄影格式/内容分布及端到端大容量图片 I/O 继续保持独立验收门；其中任何真实图库或真实
照片验证都需要项目所有者针对具体来源重新授权。

## 6. Slice M：10 万合成元数据规模门

状态：Completed，实施 commit `de9fc103a4f038614c9a7559f26042eb1b1993ef`。

本 Slice 使用固定 UUID 与纯 SQL fixture 建立 2 个 Source 和 10 万条 current Asset。偶数序号属于
folder Source，使用 `synthetic/<千位分组>/asset-<六位序号>.jpg`；奇数序号属于 Photos Source，使用
`synthetic-photos-<六位序号>` local identifier，因此两类各 5 万条。媒体类型按序号模 3 在
`public.jpeg`、`public.heic`、`public.png` 之间轮换；另建立 1 个标签，并对序号能被 10 整除的 1 万条
Asset 写入 accepted 人工决定。fixture 只写 XCTest 临时目录，不含图片字节，Photos/iCloud 下载状态因
纯元数据 fixture 不适用；测试不调用 PhotoKit，不读取 `user/`，不访问 `/Volumes/HDD2`。它验证：

1. `newest` 首两页各 100 项的 keyset 顺序、无重复与无断档，查询组回归门为 1 秒；
2. 来源与媒体类型组合筛选、人工标签筛选、文件名排序和精确搜索，查询组回归门为 2 秒；
3. v1 可移植导出完整写出并重读校验 10 万条 Asset、1 万条决定和 manifest，导出本体回归门为
   10 秒；门槛只用于发现同一目标机上的数量级退化，不是跨设备性能承诺。

1 秒与 2 秒门分别是 fixture 建立完成后、单次测试方法内两项或四项查询的累计时间；10 秒门只计
导出调用，不计 fixture 建立和 manifest 的测试断言。测试不主动清空操作系统文件缓存，也不做重复
取中位数：定向运行近似空闲单用例，完整套件则允许 Xcode 并发运行其他测试，因此同时记录两种场景。
这些数值是回归护栏，不替代后续专用 benchmark。架构要求的 1 万独立档尚无持久证据，不能由本节
冒充完成；它将与 100 万查询门在下一 Slice 一并补齐。

2026-07-17 基线环境与证据：

- Mac mini `Mac16,10`，Apple M4 10 核，16 GB 内存，macOS 26.5.1；
- 仓库位于外置 USB/APFS 固态盘 `SSD1`；XCTest fixture 由
  `FileManager.default.temporaryDirectory` 建在系统临时目录，当前落在内置 Apple Fabric/APFS 固态盘的
  `/System/Volumes/Data`，不应把两者记录为同一存储设备；
- 定向导出本体 3.754 秒，八个 JSONL 合计 51,287,131 字节；
- 完整并发测试中导出用例 7.958 秒；最终 arm64 Debug tests 780/780 通过，0 失败、0 跳过；
- 首次完整并发运行有一个既有派生图安全用例一次性返回 `derivedSourceUnavailable`；该用例隔离重跑
  通过，随后完整 780 项重跑通过，未修改无关生产代码；
- Apple Development Debug build 通过，签名身份为
  `Apple Development: 17621223203@163.com (CB9KZMUNYJ)`。

三个可审计测试入口是：

- `AssetCatalogQueryTests.testHundredThousandSyntheticAssetsKeepNewestKeysetPagesStable`；
- `AssetCatalogQueryTests.testHundredThousandSyntheticAssetsKeepFiltersSortAndSearchCorrect`；
- `PortableCatalogExportTests.testExportsHundredThousandSyntheticAssetsWithVerifiedManifest`。

第三项是 Slice M 实施 commit 中的原始名称；Slice O 在不改变默认 10 万语义的前提下将其重命名为
`PortableCatalogExportTests.testExportsConfiguredSyntheticAssetsWithVerifiedManifest`，所以下方当前 HEAD
重跑命令使用新名称。

定向门可用以下命令重跑；完整门移除三个 `-only-testing` 参数。xcresult 是可再生测试产物，不提交仓库，
权威持久证据是实施 commit 中的 fixture、断言和本节环境记录。

```text
xcodebuild test -project ImageAll.xcodeproj -scheme ImageAll \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ImageAllTests/AssetCatalogQueryTests/testHundredThousandSyntheticAssetsKeepNewestKeysetPagesStable \
  -only-testing:ImageAllTests/AssetCatalogQueryTests/testHundredThousandSyntheticAssetsKeepFiltersSortAndSearchCorrect \
  -only-testing:ImageAllTests/PortableCatalogExportTests/testExportsConfiguredSyntheticAssetsWithVerifiedManifest \
  DEVELOPMENT_TEAM=962554J6D3 CODE_SIGN_IDENTITY='Apple Development'
```

停止位置：截至 Slice M 完成时，本 Slice 不宣称 100 万容量，不基准图片解码、Feature Print 计算、
缓存压力、真实 PhotoKit 或真实目录 I/O；当时 1 万独立基线、100 万查询与 100 万可移植导出仍保持
独立验收门，后两节随后分别关闭这些门。

## 7. Slice N：1 万独立基线与 100 万查询门

状态：Completed，实施 commit `fe473812574be1e7751e04b639c5769296e0d527`。

本 Slice 复用第 6 节的固定 UUID、双 Source、三媒体类型与每十条一项 accepted 决定的纯元数据
fixture，分别在独立临时数据库中建立 1 万和 100 万条 Asset。查询计时从 fixture 完成后开始，依次验证：

1. `newest` 首两页各 100 项的 keyset 顺序、响应上限、无重复与无断档；
2. folder Source 与 `public.jpeg` 的组合筛选、accepted 标签筛选、文件名升序和精确搜索；
3. 1 万档六项累计低于 1 秒，100 万档六项累计低于 5 秒。

首次 100 万红测六项累计 12.815 秒，各项约 1.6–2.8 秒。原因是现有升序时间索引和只覆盖非空 folder
文件名的部分索引不能满足最新优先与 folder/Photos 混合排序。新增不可改写历史的
`v005_add_catalog_scale_indexes` migration，分别提供最新时间、来源+媒体类型+最新时间、全 current Asset
文件名排序索引；迁移 ID、索引方向、表达式和 partial predicate 均有 schema 回归。最终定向基线为：

- 1 万：六项累计 0.011 秒，运行时数据库、WAL 与 SHM 合计 21,949,544 字节；
- 100 万：六项累计 2.675 秒，运行时数据库、WAL 与 SHM 合计 2,168,393,928 字节；
- 100 万精确搜索单项 2.650 秒，其余五项合计约 0.025 秒；当时搜索仍是线性 `LIKE` 路径，本 Slice 未引入
  FTS 或改变搜索语义；该性能余量随后由第 16 节 Slice W 恢复；
- 相关回归 40/40、最终 arm64 Debug tests 781/781 通过，0 失败、0 跳过；Apple Development Debug
  build 通过，签名身份为 `Apple Development: 17621223203@163.com (CB9KZMUNYJ)`。

可审计入口是
`AssetCatalogQueryTests.testTenThousandAndMillionSyntheticAssetsKeepQueryEnvelopeStable`。定向重跑命令为：

```text
xcodebuild test -project ImageAll.xcodeproj -scheme ImageAll \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ImageAllTests/AssetCatalogQueryTests/testTenThousandAndMillionSyntheticAssetsKeepQueryEnvelopeStable \
  DEVELOPMENT_TEAM=962554J6D3 CODE_SIGN_IDENTITY='Apple Development'
```

停止位置：本 Slice 证明的是合成元数据查询正确性与同机回归包络，不宣称真实 UI 滚动、图片 I/O、
PhotoKit/iCloud 或端到端 100 万容量已经验收；2.17 GB 是 SQLite 主库与 sidecar 的运行时占用，不是
可移植导出体积。100 万可移植导出随后由第 8 节作为独立、显式运行的规模门关闭，避免每次完整测试
都写出约十倍于 10 万基线的数据包。

## 8. Slice O：100 万可移植导出规模门

状态：Completed，实施 commit `992b51d381eac0e72ef8c71cc772770e3de076a8`。

现有导出规模用例改为单一可复现入口：默认仍建立并导出 10 万 Asset，只有 XCTest 进程的
`IMAGEALL_SYNTHETIC_EXPORT_ASSET_COUNT` 明确等于 `1000000` 时才运行 100 万档；其他值直接失败。这样
常规完整测试继续保留 10 秒回归门，100 万档使用 90 秒同机护栏并只在明确调用时写出大数据包。

2026-07-17 定向证据：

- 100 万 Asset、10 万 accepted 决定、2 个 Source 和 1 个 Tag，共 1,100,003 条导出记录；
- 八个 JSONL 合计 512,867,131 字节，导出调用 36.201 秒，manifest 中每个文件的 record count、byte
  count 与 64 字符十六进制 SHA-256 均通过断言；
- fixture、SQLite sidecar、临时发布目录和最终测试数据包均位于 XCTest 临时根并在测试结束后清理；
- 默认 Portable Export 回归 4/4、最终 arm64 Debug tests 782/782 通过，0 失败、0 跳过；Apple
  Development Debug build 通过，签名身份仍为
  `Apple Development: 17621223203@163.com (CB9KZMUNYJ)`。

直接在 `xcodebuild test` 前设置 shell 环境变量不会传入当前 macOS XCTest 进程，因而不能作为有效
百万证据。可复制流程必须先 `build-for-testing`，再复制生成的 `.xctestrun` 到同一 Build/Products
目录（保持 `__TESTROOT__` 相对路径有效），注入测试环境后 `test-without-building`：

```text
set -euo pipefail

xcodebuild build-for-testing -project ImageAll.xcodeproj -scheme ImageAll \
  -destination 'platform=macOS,arch=arm64' \
  DEVELOPMENT_TEAM=962554J6D3 CODE_SIGN_IDENTITY='Apple Development'

BUILD_DIR="$(xcodebuild -project ImageAll.xcodeproj -scheme ImageAll \
  -destination 'platform=macOS,arch=arm64' -showBuildSettings 2>/dev/null | \
  awk -F ' = ' '/^[[:space:]]*BUILD_DIR = / { print $2; exit }')"
XCTESTRUN_COUNT="$(find "$BUILD_DIR" -maxdepth 1 -name 'ImageAll_ImageAll_*.xctestrun' \
  ! -name '*million-export*' -print | wc -l | tr -d ' ')"
test "$XCTESTRUN_COUNT" -eq 1
BASE_XCTESTRUN="$(find "$BUILD_DIR" -maxdepth 1 -name 'ImageAll_ImageAll_*.xctestrun' \
  ! -name '*million-export*' -print -quit)"
MILLION_XCTESTRUN="${BASE_XCTESTRUN%.xctestrun}-million-export.xctestrun"
cleanup() { test ! -e "$MILLION_XCTESTRUN" || unlink "$MILLION_XCTESTRUN"; }
trap cleanup EXIT
cp "$BASE_XCTESTRUN" "$MILLION_XCTESTRUN"
/usr/libexec/PlistBuddy -c \
  'Add :TestConfigurations:0:TestTargets:0:EnvironmentVariables:IMAGEALL_SYNTHETIC_EXPORT_ASSET_COUNT string 1000000' \
  "$MILLION_XCTESTRUN"
INJECTED_VALUE="$(/usr/libexec/PlistBuddy -c \
  'Print :TestConfigurations:0:TestTargets:0:EnvironmentVariables:IMAGEALL_SYNTHETIC_EXPORT_ASSET_COUNT' \
  "$MILLION_XCTESTRUN")"
test "$INJECTED_VALUE" = "1000000"

xcodebuild test-without-building -xctestrun "$MILLION_XCTESTRUN" \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ImageAllTests/PortableCatalogExportTests/testExportsConfiguredSyntheticAssetsWithVerifiedManifest
```

停止位置：本 Slice 关闭合成元数据的 100 万 JSONL 导出正确性与同机时间门，不测导入、压缩、加密、
峰值 RSS、真实图片字节、PhotoKit/iCloud 或用户所选外置卷写入；这些结果不能单独升级为端到端 100 万
资产容量承诺。

## 9. Slice P：缓存清理压力门

状态：Completed，实施 commit `878fdfe77707a78e8351c432421be4a51533eaf7`。

本 Slice 在 XCTest 临时缓存根建立 10,000 条 schema-valid `derived_image_cache_entry` 与 10,000 个对应
对象文件。它是只供清理路径使用的内容无关压力 fixture：条目使用固定 UUID、同一合成 Asset 的不同
正整数 content revision 和 `gridSmall` 256×256 登记字段，以单字节 `0xAB` 对象及其真实 SHA-256/字节数
保持登记与文件自洽；这些 revision 不代表生产历史可达状态，单字节对象也不是可解码 JPEG。对象仍按
生产两位 shard 布局写入。fixture 建立完成后调用不解码对象内容的真实
`DerivedImageCacheService.clearCache()`，验证：

1. 精确失效 10,000 条登记和 10,000 登记字节，删除 10,000 个对象和 10,000 实际字节；
2. `partialReclaim == false`，登记用量、objects 和 staging 全部归零；
3. 测试来源树前后逐项相同，清理路径不读取或修改真实来源；
4. 清理调用低于 15 秒；fixture 建立、10,000 次对象写入和清理后的断言不计入该时间门。

2026-07-17 定向基线为 0.867 秒。缓存契约、配额与互斥相关回归 44/44，最终 arm64 Debug tests
783/783 通过，0 失败、0 跳过；Apple Development Debug build 通过，签名身份仍为
`Apple Development: 17621223203@163.com (CB9KZMUNYJ)`。可审计入口与重跑命令为：

```text
xcodebuild test -project ImageAll.xcodeproj -scheme ImageAll \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ImageAllTests/DerivedImageContractTests/testClearCacheConvergesTenThousandRegisteredObjectsWithinScaleGate \
  DEVELOPMENT_TEAM=962554J6D3 CODE_SIGN_IDENTITY='Apple Development'
```

停止位置：本 Slice 关闭显式全量预览缓存清理的 10,000 对象压力门，不模拟 20 GiB 实际缓存、外置卷
吞吐、长时间并发生成、Feature Print 清理或自动定时维护，也不改变 Slice K 的产品范围与配额策略。

## 10. Slice Q：发布前隐私与故障回归门

状态：Completed，实施 commit `576ebd9b02092cbe7505b82442f040d8bc59afc1`。

本 Slice 先审计第 14、15、17 节与现有测试，再以现有公开行为组成发布回归矩阵。已存在的目录来源
只读快照、相对路径拒绝与事务回滚，派生缓存 no-follow、外部 sentinel 和故障收敛，快照建立/恢复/
替换与启动失败原子性，Job 安全错误码，Photos 本地只读策略，以及个性化人工决定优先级均直接复用，
没有为本门重复实现第二套机制。

审计发现可移植导出的“发布前故障”已有注入覆盖，但第 2.4 节要求的“数据文件写入故障后清理临时
数据包”没有直接证据。实施因此只增加一个默认空操作的文件写入故障边界；导出器在写每个 JSONL 前
调用它，把任意注入异常收敛为 `writeFailed`，随后沿用既有失败清理路径。新增
`PortableCatalogExportTests.testDataFileWriteFailureRemovesTemporaryBundleAndPublishesNothing` 先以退出码
65 得到红灯，再验证 `assets.jsonl` 写入故障不会发布最终目录，且所选父目录不留下本次临时包。

命名回归门固定覆盖以下 20 个 XCTest class：

- 目录来源：`FolderReconcilePrivacyRegressionTests`、`FolderReconcileReadonlyMatrixTests`、
  `FolderReconcileAcceptanceMatrixTests`、`FolderReconcileLeaseMatrixTests`、
  `FolderReconcileTransactionTests`；
- 派生缓存：`DerivedImagePrivacyRegressionTests`、`DerivedImageFaultTests`、
  `DerivedImageHardeningTests`、`DerivedImageQuotaTests`；
- 数据库恢复：`CatalogSnapshotCreationTests`、`CatalogSnapshotHashingTests`、
  `CatalogSnapshotManifestTests`、`CatalogSnapshotReplacementTests`、`CatalogSnapshotRestoreTests`、
  `CatalogBootstrapFailureTests`；
- 用户事实与来源：`PortableCatalogExportTests`、`JobSafeBoundaryTests`、
  `PersonalizationPersistenceTests`、`FullLibrarySuggestionsJobTests`、`PhotosIntegrationTests`。

可复制的命名回归入口为：

```text
xcodebuild test -project ImageAll.xcodeproj -scheme ImageAll \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ImageAllTests/FolderReconcilePrivacyRegressionTests \
  -only-testing:ImageAllTests/FolderReconcileReadonlyMatrixTests \
  -only-testing:ImageAllTests/FolderReconcileAcceptanceMatrixTests \
  -only-testing:ImageAllTests/FolderReconcileLeaseMatrixTests \
  -only-testing:ImageAllTests/FolderReconcileTransactionTests \
  -only-testing:ImageAllTests/DerivedImagePrivacyRegressionTests \
  -only-testing:ImageAllTests/DerivedImageFaultTests \
  -only-testing:ImageAllTests/DerivedImageHardeningTests \
  -only-testing:ImageAllTests/DerivedImageQuotaTests \
  -only-testing:ImageAllTests/CatalogSnapshotCreationTests \
  -only-testing:ImageAllTests/CatalogSnapshotHashingTests \
  -only-testing:ImageAllTests/CatalogSnapshotManifestTests \
  -only-testing:ImageAllTests/CatalogSnapshotReplacementTests \
  -only-testing:ImageAllTests/CatalogSnapshotRestoreTests \
  -only-testing:ImageAllTests/PortableCatalogExportTests \
  -only-testing:ImageAllTests/CatalogBootstrapFailureTests \
  -only-testing:ImageAllTests/JobSafeBoundaryTests \
  -only-testing:ImageAllTests/PersonalizationPersistenceTests \
  -only-testing:ImageAllTests/FullLibrarySuggestionsJobTests \
  -only-testing:ImageAllTests/PhotosIntegrationTests \
  DEVELOPMENT_TEAM=962554J6D3 CODE_SIGN_IDENTITY='Apple Development'
```

完整回归与独立构建入口为：

```text
xcodebuild test -project ImageAll.xcodeproj -scheme ImageAll \
  -destination 'platform=macOS,arch=arm64' \
  DEVELOPMENT_TEAM=962554J6D3 CODE_SIGN_IDENTITY='Apple Development'

xcodebuild build -project ImageAll.xcodeproj -scheme ImageAll -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  DEVELOPMENT_TEAM=962554J6D3 CODE_SIGN_IDENTITY='Apple Development'
```

2026-07-17 的 arm64 定向结果为 230/230，0 失败、0 跳过；完整 Debug tests 为 784/784，0 失败、
0 跳过。独立 Debug build 通过，产物签名为
`Apple Development: 17621223203@163.com (CB9KZMUNYJ)`，Team ID 为 `962554J6D3`。PhotoKit 写入 API
负向模式的原始 `rg` 退出码为 1。当前已知的生产日志/控制台 API 表面只有
`CatalogStartupModel.swift` 中一个 `Logger` 和四个 `logger.info` 调用；逐项检查确认其只记录固定状态、
stage 与安全 reason token，同一行敏感标识负向模式的原始退出码也为 1。这个结论只覆盖下列命令列出
并检查的当前源码表面，不冒充对任意未来日志封装或多行数据流的证明：

```text
set +e
rg -n \
  'performChanges|PHAssetChangeRequest|PHAssetCollectionChangeRequest|PHCollectionListChangeRequest|creationRequestForAsset|deleteAssets' \
  ImageAll --glob '*.swift' --glob '!Assets.xcassets/**'
photos_write_status=$?

rg -n \
  '(?:logger|os_log).*?(?:\.path\b|bookmark|localIdentifier|photos_local_identifier|payload)' \
  ImageAll --glob '*.swift' --glob '!Assets.xcassets/**'
logging_sensitive_status=$?
set -e
test "$photos_write_status" -eq 1
test "$logging_sensitive_status" -eq 1

rg -n \
  'Logger\(|logger\.(?:trace|debug|info|notice|warning|error|critical)\(|os_log\(|NSLog\(|debugPrint\(|(?:^|[^[:alnum:]_])print\(' \
  ImageAll --glob '*.swift' --glob '!Assets.xcassets/**'
```

自动化证据全部使用 XCTest 临时目录、合成数据库和测试替身；未读取 `user/`，未访问或遍历
`/Volumes/HDD2`，也未调用 Photos 写入 API。停止位置：本 Slice 关闭代码级发布隐私/故障回归，不把
源代码静态检查冒充运行时权限证明；真实 macOS 用户会话权限回归、真实 UI/图片 I/O 与端到端容量门、
三个真实标签校准仍然开放，任何真实照片验证仍需单独授权。

## 11. Slice R：100 图端到端图片 I/O 基线

状态：Completed，实施 commit `2a0a5cb205b26a46294e09906a4a74df7266e138`。

本 Slice 在 XCTest 临时来源根预先生成 100 个不同路径和 Asset ID 的有效 JPEG 文件。每个文件使用
ImageIO 编码同一张不透明的 128×96 合成图；图片字节在计时前生成，因此该 fixture 能证明真实文件
解码和缓存写入路径，但不代表 100 张不同摄影内容，也不包含真实用户数据。测试随后复用生产
folder reconcile 队列、handler 与 coordinator 完成来源对账，通过生产目录查询按 `fileName` 升序取回
100 个 Asset 并读取终止空页，再调用生产 `DerivedImageCacheService` 为每项生成 `gridRegular`
512×512 派生图，最后以相同请求进行第二遍缓存命中。它验证：

1. 首遍 100 项全部返回 `generated`、512×512 且载荷非空，次遍 100 项全部返回 `cacheHit`；
2. 次遍不重新开启来源 bookmark 访问，派生图服务两遍请求期间的安全作用域 start/stop 次数平衡；
3. 缓存登记、对象文件均精确为 100，staging 为 0；首遍返回载荷合计 498,900 字节；
4. 来源树在对账、查询、生成与命中前后逐项相同；
5. 从生产对账开始到第二遍命中结束的流水线低于 30 秒。该宽门只用于发现同一目标机上的数量级退化，
   不是跨设备性能承诺。

2026-07-17 的定向 XCTest 用例耗时为 0.570 秒，内部计时如下：

- folder reconcile：0.058877291 秒；
- 100 项查询和终止空页：0.003925792 秒；
- 首遍 100 张缩略图生成：0.398582750 秒；
- 次遍 100 项缓存命中：0.044828875 秒；
- 上述生产流水线合计：0.506289042 秒。

可审计入口与定向重跑命令为：

```text
xcodebuild test -project ImageAll.xcodeproj -scheme ImageAll \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ImageAllTests/DerivedImageContractTests/testHundredJPEGsReconcileQueryGenerateAndHitCacheWithinImageIOGate \
  DEVELOPMENT_TEAM=962554J6D3 CODE_SIGN_IDENTITY='Apple Development'
```

相关的派生图契约、渲染、指纹、目录对账与查询回归为 88/88；最终 arm64 Debug tests 为 785/785，
0 失败、0 跳过。独立 Debug build 通过，签名身份仍为
`Apple Development: 17621223203@163.com (CB9KZMUNYJ)`，Team ID 为 `962554J6D3`。

fixture、数据库、缓存和派生图均位于 XCTest 临时根，未读取 `user/`，未访问或遍历 `/Volumes/HDD2`，
未调用 PhotoKit。停止位置：本 Slice 不覆盖 SwiftUI frame/滚动流畅度、并发冷启动网格请求、
Photos/iCloud、真实摄影内容或混合格式分布，也不执行 1 万、10 万或 100 万真实图片解码。因此它只关闭
100 个合成有效 JPEG 的生产后端管线基线，不能升级为真实 UI 或端到端大容量图片 I/O 已验收；真实
macOS 权限回归和三个真实标签校准也仍然开放。

## 12. Slice S：混合静态格式并发图片 I/O 基线

状态：Completed，实施 commit `a3bda68f35e1a131cc7d8f737bf09410b02530e0`。

本 Slice 在 XCTest 临时来源根建立 30 个有效图片 fixture，固定为 JPEG、PNG、HEIC、HEIF、TIFF、WebP
六种受支持静态格式各 5 个。JPEG、PNG 使用 ImageIO 编码的 128×96 与 96×128 合成图，HEIC、TIFF
使用宿主 ImageIO 编码，HEIF、WebP 使用仓库测试中已有的静态有效 fixture。它们能验证格式识别、解码
和缓存写入，不代表 30 张不同摄影内容，也不冒充真实摄影格式/内容分布。

测试复用生产 folder reconcile 与目录查询，随后通过最大并发数为 4 的生产
`LibraryAssetImageLoader` 和真实 `DerivedImageCacheService` 对 30 项执行首遍冷加载与次遍热加载。
它验证：

1. 查询结果中六种媒体类型均精确为 5 项，首遍和次遍均得到 30 个可解码的 512×512 载荷；
2. 次遍不重新开启来源 bookmark scope，两遍期间来源访问 start/stop 严格平衡；
3. cache entry 与 object 精确为 30，staging 为 0；
4. 来源树在生产对账、并发冷加载和热加载前后逐项相同；
5. 整个生产流水线低于 30 秒。该宽门只用于发现同一目标机上的数量级退化，不是跨设备性能承诺。

2026-07-17 的定向 XCTest 用例耗时为 0.334 秒，内部冷加载为 0.115787666 秒、热加载为
0.008380458 秒，生产流水线合计为 0.154684792 秒。可审计入口与定向重跑命令为：

```text
xcodebuild test -project ImageAll.xcodeproj -scheme ImageAll \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ImageAllTests/DerivedImageContractTests/testMixedSupportedFormatsReconcileAndLoadConcurrentlyThroughLibraryPipeline \
  DEVELOPMENT_TEAM=962554J6D3 CODE_SIGN_IDENTITY='Apple Development'
```

首次运行暴露了测试替身 `TestBookmarkPort` 的并发计数数据竞争；本 Slice 仅用 `NSLock` 保护该测试
替身计数，没有改变生产行为。相关格式、派生图、对账和查询回归为 97/97；最终 arm64 Debug tests 为
786/786，0 失败、0 跳过。独立 Debug build 与签名验证通过。

所有输入、数据库和缓存均位于 XCTest 临时根，未读取 `user/`，未访问或遍历 `/Volumes/HDD2`，未调用
PhotoKit。停止位置：本 Slice 不覆盖不同真实摄影内容的代表性分布、SwiftUI frame/滚动、Photos/iCloud、
真实 macOS 权限或 1 万、10 万、100 万图片解码；它只关闭六种受支持静态格式的生产后端并发管线门。

## 13. Slice T：可移植导出目标与来源隔离

状态：Completed，实施 commit `ebc7c9f9aab17cac17f243400fda440387aecbcd`；安全回归补强 commits
`f7dcddfb27d8087aea223143d6203735af5ff7cb`、`6ed2c5cfd7c420d36894a55b50e8303ea8f787ce`。

可移植导出必须写入用户在系统面板选择的父目录，因此 production target 保留 app-wide
`com.apple.security.files.user-selected.read-write`。该 entitlement 不改变来源契约：文件夹来源
bookmark 仍显式包含 `.securityScopeAllowOnlyReadAccess`，导出 scope 不持久化。为避免用户把导出
位置选到原图来源树内或其上层，本 Slice 在 `PortableCatalogExporter` 创建临时目录前增加来源隔离预检：

1. 检查全部已记录 folder Source，包括当前未启用的来源；
2. 目标与来源相同、目标位于来源内、目标包含来源时抛出 `destinationOverlapsSource`；
3. 来源查询、bookmark 解析、来源 scope 开启或目录关系判断无法确定时抛出
   `destinationIsolationIndeterminate`，不尝试写入；
4. 只有与全部来源均可证明 disjoint 的目标才允许进入原有原子导出流程。

两条定向测试均只使用 XCTest 临时根。第一条建立来源、子目录、共同父目录、独立导出目录和来源
sentinel，逐项验证三种重叠目标均拒绝、独立目标通过、sentinel 字节不变且所有来源 scope start/stop
平衡。第二条同时建立两个来源，把其中一个改为 disabled，验证该来源仍阻止其后代目标；并直接验证
bookmark 解析失败、scope 开启失败、目录关系不确定和目录库存在不可解码来源记录时都返回
`destinationIsolationIndeterminate`。可审计入口与重跑命令为：

```text
xcodebuild test -project ImageAll.xcodeproj -scheme ImageAll \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ImageAllTests/PortableCatalogExportTests/testSourceIsolationRejectsOverlappingExportDestinationsAndAllowsDisjointDirectory \
  -only-testing:ImageAllTests/PortableCatalogExportTests/testSourceIsolationChecksDisabledSourcesAndFailsClosedWhenIsolationIsIndeterminate \
  DEVELOPMENT_TEAM=962554J6D3 CODE_SIGN_IDENTITY='Apple Development'
```

相关导出、entitlement、bookmark、来源重叠、Composition Root 和 Workspace 回归为 62/62；最终 arm64
Debug tests 为 788/788，0 失败、0 跳过。独立 Debug build、`codesign --verify --deep --strict` 和实际
entitlement 检查均通过；签名身份为 `Apple Development: 17621223203@163.com (CB9KZMUNYJ)`，Team ID
为 `962554J6D3`，实际能力包含 App Sandbox、app-scope bookmark、user-selected read-write、Photos 读取
和 Debug `get-task-allow`。

本 Slice 只使用临时目录和合成目录库，未读取 `user/`，未访问或遍历 `/Volumes/HDD2`，未调用 Photos
写入 API。停止位置：它不把自动化测试冒充真实 `NSOpenPanel` 沙盒会话验证，也不关闭真实 macOS 权限
人工回归；它只保证生产服务在开始任何导出临时写入前拒绝来源重叠或无法确认的目标。

## 14. Slice U：导出隔离故障的可操作提示

状态：Completed，实施 commit `443656d8bb5138e049e2e96b63aa04657ede715f`；文案与测试补强 commit
`d3200c9e47605a57a5179da712e4d3dd63aafda1`。

Slice T 已在写入前安全拒绝重叠或无法确认的导出位置，但 Workspace 原先把所有导出异常统一显示为
“用户数据导出未完成”。本 Slice 保留既有导出 Port 和界面结构，只在 `LibraryWorkspaceModel` 将两个
稳定的基础设施错误映射为独立、无敏感信息的可观察状态：

1. `destinationOverlapsSource` 显示“导出位置不能与已添加的文件夹来源重叠，请选择其他文件夹。”；
2. `destinationIsolationIndeterminate` 显示“无法确认导出位置与来源隔离，尚未开始导出。请重新授权来源或
   选择其他位置；仍失败时请停止导出。”；这是保守拒绝，不表示已确认目标与来源重叠；
3. 其他导出错误继续使用原有通用失败提示，成功与取消行为不变；任何提示都不包含绝对路径、bookmark、
   Photos identifier、数据库信息或底层错误文本。

两个新增模型测试从公开的 `exportPortableUserData()` 行为触发精确错误，并断言最终 notice；两个文案测试
直接断言 SwiftUI notice 映射返回的完整固定字符串，原有通用失败测试同时保护兜底分支。自动化只证明状态
与文案映射，不证明真实窗口中的布局、可见性或交互，本 Slice 不以此冒充真实窗口交互测试。可审计入口与
重跑命令为：

```text
xcodebuild test -project ImageAll.xcodeproj -scheme ImageAll \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ImageAllTests/LibraryWorkspaceModelTests/testPortableExportSourceOverlapPublishesActionableNotice \
  -only-testing:ImageAllTests/LibraryWorkspaceModelTests/testPortableExportIndeterminateIsolationPublishesActionableNotice \
  -only-testing:ImageAllTests/LibraryWorkspaceModelTests/testPortableExportFailurePublishesSafeNotice \
  -only-testing:ImageAllTests/LibraryWorkspaceModelTests/testPortableExportSourceOverlapNoticeExplainsSafeRecovery \
  -only-testing:ImageAllTests/LibraryWorkspaceModelTests/testPortableExportIndeterminateIsolationNoticeFailsClosed \
  DEVELOPMENT_TEAM=962554J6D3 CODE_SIGN_IDENTITY='Apple Development'
```

Workspace 与可移植导出相关回归为 48/48；最终 arm64 Debug tests 为 792/792，0 失败、0 跳过。独立
Debug build 与 `codesign --verify --deep --strict` 通过；签名身份为
`Apple Development: 17621223203@163.com (CB9KZMUNYJ)`，Team ID 为 `962554J6D3`。

本 Slice 的测试只使用注入错误和 XCTest 临时目录 URL，未读取 `user/`，未访问或遍历 `/Volumes/HDD2`，
未调用 PhotoKit。停止位置：它不自动选择新目录、不自动重新授权来源、不显示发生问题的具体来源，也不
关闭真实 `NSOpenPanel` 沙盒会话、真实 macOS 权限或 SwiftUI 人工交互验收门。

## 15. Slice V：隔离沙盒合成文件夹的真实 App 与导出会话验收

状态：Completed（验证切片，无可执行实现改动）；验收基线
`40a6d9ee4c7bd6657006d90c42a97a08bf326400`。完整可复核命令、输出摘要和截图哈希索引见
[`STAGE-4-V-SESSION-EVIDENCE.md`](./STAGE-4-V-SESSION-EVIDENCE.md)。

本 Slice 不新增 UI Test target，也不修改已有 Xcode 工程配置。验收构建使用独立 DerivedData
`/tmp/ImageAll-Stage4V-20260717-1200/derived-data`，并通过命令行覆盖
`PRODUCT_BUNDLE_IDENTIFIER=com.gwlee.ImageAll.Stage4V.20260717`。启动前该 Bundle ID 的容器不存在；
启动后目录库只建立在
`~/Library/Containers/com.gwlee.ImageAll.Stage4V.20260717/Data/Library/Application Support/ImageAll/`。
构建通过 `codesign --verify --deep --strict`，签名身份为
`Apple Development: 17621223203@163.com (CB9KZMUNYJ)`，Team ID 为 `962554J6D3`。这使本次会话与
正式 `com.gwlee.ImageAll` 容器隔离。构建按正常流程读取实时 Xcode 工程，但本 Slice 未审阅既有工程
差异，未编辑、暂存或提交与本 Slice 无关的 App Icon 和工程文件修改；因此这里只宣称运行数据隔离，
不宣称构建产物不受实时工程配置影响。

测试来源为 `/tmp/ImageAll-Stage4V-20260717-1200/source` 中 100 张由 AppKit 当场生成的有效 PNG；每张使用
不同尺寸、颜色和 `Stage 4-V <序号>` 文本，不含真实照片。真实 App 会话完成并观察到：

1. 从空目录库点击“连接照片文件夹…”，通过真实 `NSOpenPanel` 选择测试来源；隔离数据库随后包含 1 个
   active folder Source、100 个 Asset；
2. Lazy 网格顶部与底部均显示不同的合成缩略图，滚动条从 `0` 到 `1`，证明真实 SwiftUI 网格可以滚动
   到 100 项数据集末端；
3. 选择 `synthetic-001.png` 后按 Space，中央 `singlePhotoView` 显示该图，检查器同时显示文件名、来源、
   `public.png`、`720 × 540` 和可用状态；Escape 返回网格；
4. 通过真实“导出用户数据”面板选择不相交的 `export-disjoint`，成功提示为“已导出 201 条记录到
   `ImageAll-Export-20260717-045550Z`”；manifest 的记录数合计为 201（100 Asset、100 file fingerprint、
   1 Source），八个 JSONL 的 SHA-256 均通过重算；
5. 再次打开导出面板并选择来源的祖先目录 `/tmp/ImageAll-Stage4V-20260717-1200`，界面显示
   “导出位置不能与已添加的文件夹来源重叠，请选择其他文件夹。”；该祖先目录没有产生
   `ImageAll-Export-*`，证明拒绝发生在发布数据包前；
6. 退出 App 后以同一独立 Bundle ID 再次启动，不重新打开文件夹面板，并点击“立即重扫”；
   `scan_generation` 从 1 变为 2，completed `folder.reconcile.v1` Job 从 1 个变为 2 个，Asset 保持 100，
   源树哈希不变。该重扫必须重新解析持久 bookmark、开启安全作用域并枚举来源，证明跨进程恢复不是只
   显示数据库投影或既有缓存。

源目录验收前后均为 100 个文件，逐文件 SHA-256 清单摘要同为
`4e50ee0e5f582d89346a0d1af32f46e33d67b0008d5140fa196e37f5ac4e5ae4`，`cmp` 通过。会话截图只存放在
上述可丢弃临时根的 `evidence/`，不作为产品数据或长期仓库资产；脱敏命令、结果与截图哈希已经持久记录
在本节链接的会话证据中。隔离 App 已正常退出。验收未点击“连接 Apple Photos…”，未请求 Photos 权限，
未读取 `user/`，未访问或遍历 `/Volumes/HDD2`，也未把任何输出写入照片来源树。

停止位置：本 Slice 关闭的是合成临时文件夹上的真实 `NSOpenPanel`、App 沙盒 bookmark 创建与跨进程
重启后的无面板重扫、100 项网格滚动、单图标准预览、不相交导出和来源祖先目标的重叠拒绝提示。它不证明
Apple Photos 授权、`destinationIsolationIndeterminate` 的真实窗口路径、真实摄影内容或全部 SwiftUI
交互，不使用真实标签校准样本，也不替代大容量图片 I/O 与发布包验收。

## 16. Slice W：百万资产搜索性能余量恢复

状态：Completed，实施 commit `bea02c58934cf7e8ecd01b92100c868ef1f619b4`。

Stage 2-G 的干净提交快照在 unsigned 全量测试中以 10.625 秒超过既有 5 秒门；同一百万资产查询隔离
复跑为 4.929 秒，其中 search 单项为 4.858 秒。Slice W 不放宽阈值，也不改变文件名、相对路径、来源
显示名和标签名的字面子串语义、结果集合、排序或分页。先写入“百万档六项累计低于 2 秒”的余量回归，
旧实现红测为 3.883 秒；嵌套子查询尝试回归到 11.618 秒，单纯预解析来源与标签仍为 7.251 秒，均未保留。

最终实现只追加 `v006_add_asset_text_search` migration：

- 为 Asset 的 `file_name`、`relative_path` 建立 external-content FTS5 trigram 候选索引，并用
  insert/delete/update trigger 与 `asset` 保持同步；migration rebuild 为既有 v005 数据回填；
- 三个及以上 Unicode scalar 的归一化搜索先以引用后的字面 phrase 缩小文件名/相对路径候选，再用原有
  `LIKE ... ESCAPE '\\'` 复核精确语义，避免 FTS 候选误改变结果；不足三个 scalar 继续走原有 LIKE；
- 来源显示名和标签名只在小表中预解析匹配 ID，人工标签决定仍按 ID 参与主查询；
- migration、FTS shadow table、trigger、回填、更新和删除都有 schema/行为回归；特殊通配符、反斜杠、
  引号、注入字符串、四类搜索字段和双字符 fallback 保持通过。

2026-07-17 在只含 `bea02c5` 已提交内容、且不含 `user/` 的干净归档中，证据为：

- unsigned arm64 Debug tests 811/811 通过：
  `/tmp/ImageAll-Verify-bea02c5-Full-20260717-1650.xcresult`；
- 1 万档六项累计 0.012153125 秒，其中 search 0.001453208 秒；100 万档六项累计 0.208921334 秒，
  其中 search 0.128958917 秒；attachments 位于
  `/tmp/ImageAll-Verify-bea02c5-Full-Attachments-20260717-1720`；
- 100 万运行时数据库、WAL 与 SHM 合计 2,360,339,760 字节，比 Slice N 的 2,168,393,928 字节增加
  191,945,832 字节，约 8.85%；这是索引换取稳定搜索余量的已记录容量代价；
- Apple Development entitlement 1/1：
  `/tmp/ImageAll-Verify-bea02c5-SignedEntitlement-20260717-1722.xcresult`；独立 signed Debug bundle 位于
  `/tmp/ImageAll-Verify-bea02c5-SignedBuild-DD-20260717-1722/Build/Products/Debug/ImageAll.app`，bundle ID
  `com.gwlee.ImageAll.Stage4W.Clean.20260717`，由 Team `962554J6D3` 签名并通过
  `codesign --verify --deep --strict`；entitlement 未超出批准项与 Debug `get-task-allow`。

自动化只建立合成元数据和临时数据库，不读取图片字节，不调用 PhotoKit，不读取 `user/`，不访问或遍历
`/Volumes/HDD2`。本 Slice 关闭查询回归余量，但只用小型 v005 fixture 证明 v006 回填正确；既有百万资产
目录库升级到 v006 的耗时、峰值工作副本空间与容量预检是否足够仍未量化，应作为下一独立规模门验证，
不能由查询完成后的数据库体积替代。
