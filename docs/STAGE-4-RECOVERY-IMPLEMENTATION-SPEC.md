# ImageAll 阶段 4：可恢复发布纵切片实施规格

> 状态：Approved for implementation
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

三个切片通过后，阶段 4 仍未宣称完整完成。10 万合成元数据基准已经按第 6 节关闭，1 万独立查询基线
与 100 万查询门已经按第 7 节关闭；100 万可移植导出、缓存压力测试、发布前隐私/故障回归、三个真实
标签校准以及真实 macOS 权限回归继续保持独立验收门；其中任何真实图库或真实照片验证都需要项目
所有者针对具体来源重新授权。

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

定向门可用以下命令重跑；完整门移除三个 `-only-testing` 参数。xcresult 是可再生测试产物，不提交仓库，
权威持久证据是实施 commit 中的 fixture、断言和本节环境记录。

```text
xcodebuild test -project ImageAll.xcodeproj -scheme ImageAll \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ImageAllTests/AssetCatalogQueryTests/testHundredThousandSyntheticAssetsKeepNewestKeysetPagesStable \
  -only-testing:ImageAllTests/AssetCatalogQueryTests/testHundredThousandSyntheticAssetsKeepFiltersSortAndSearchCorrect \
  -only-testing:ImageAllTests/PortableCatalogExportTests/testExportsHundredThousandSyntheticAssetsWithVerifiedManifest \
  DEVELOPMENT_TEAM=962554J6D3 CODE_SIGN_IDENTITY='Apple Development'
```

停止位置：本 Slice 不宣称 100 万容量，不基准图片解码、Feature Print 计算、缓存压力、真实 PhotoKit
或真实目录 I/O。1 万独立基线与 100 万查询门由下一节关闭；100 万可移植导出仍保持独立验收门。

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
- 100 万精确搜索单项 2.650 秒，其余五项合计约 0.025 秒；搜索仍是线性 `LIKE` 路径，本 Slice 不引入
  FTS 或改变搜索语义；
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
可移植导出体积。100 万可移植导出应作为独立、显式运行的规模门，避免每次完整测试都写出约十倍于
10 万基线的数据包。
