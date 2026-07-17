# ImageAll 阶段 1 实施规格

> 状态：Implementation in progress；切片 1～4 与加速纵切片 A～F 已通过<br>
> 日期：2026-07-16<br>
> 产品批准：`UI-001`～`UI-011`、macOS 15+ / Apple Silicon only、静态格式允许清单、本地自用签名<br>
> 已批准实现基线：阶段 0 `main@892f4e29e1ebf492c1540c5a29d9c54abc05a78f`<br>
> 当前批准实现：加速纵切片 F `main@fe21362269c955abf224201f1ba1bbc132cebab7`<br>
> 当前阶段输入：[`STAGE-1-BACKEND-ARCHITECTURE.md`](./STAGE-1-BACKEND-ARCHITECTURE.md) 与 [`STAGE-1-PRODUCT-UI-SPEC.md`](./STAGE-1-PRODUCT-UI-SPEC.md)<br>
> 实施者：通常为 Cursor CLI，仅 `Composer 2.5 Fast`；Cursor 额度恢复前按仓库临时授权由 Codex 直接实施

## 1. 目标与完成定义

阶段 1 建立第一个真实但只读的文件夹照片闭环：

```text
用户明确连接文件夹
→ app-scoped bookmark 跨启动恢复
→ 流式 generation 对账
→ 支持图片逐步进入统一图库
→ 原子生成受配额管理的缩略图
→ 浏览、搜索、筛选和人工标签
→ 离线、权限失效、单文件错误和任务中断可恢复
```

阶段 1 完成必须同时满足：

1. 只处理用户通过系统选择器授权的 folder Source；
2. 来源端零写入，不创建 sidecar、隐藏文件或元数据；
3. JPEG、PNG、HEIC/HEIF、TIFF、WebP 能进入目录库；GIF、RAW、PDF、视频与 Live Photo 不进入支持集；
4. 不完整扫描不产生批量 `missing`，离线/失权不释放 locator 或人工标签；
5. 资产批次、checkpoint、generation 完成和 successor Job 符合单事务契约；
6. 三类派生缓存按批准尺寸原子发布，只写 ImageAll 自有 Caches；
7. 统一图库、来源、人工标签、ALL/ANY、系统状态与稳定 keyset pagination 可用；
8. 三栏工作台、网格、单图查看、Inspector、活动入口和轻量 `Command-K` 符合产品规格；
9. App 重启、任务中断、拔盘、重新授权、损坏图片和低缓存空间均有可观察且保守的恢复行为；
10. 自动化只使用临时合成 fixture，整个阶段不读取 `/Volumes/HDD2`。

完成只表示文件夹资产闭环通过；Apple Photos、AI 建议、相似组、Compare、Smart Collection、自动化规则和发布签名仍不属于阶段 1。

## 2. 不可突破的全局边界

### 2.1 分层

```text
SwiftUI / AppKit adapter
        ↓
Application ports + presentation state
        ↓
Domain rules
        ↑
Infrastructure adapters (GRDB / Foundation / Image I/O / FSEvents)
```

- Domain 不导入 GRDB、SwiftUI、AppKit、CoreServices 或 ImageIO；
- Application 不暴露 `DatabasePool`、SQL、security-scoped URL、FSEvent flags 或缓存绝对路径；
- View 不直接访问数据库、bookmark、文件系统或 Image I/O；
- AppKit 只负责系统目录选择等平台界面适配，不能承载目录事实；
- Infrastructure 不反向依赖 SwiftUI。

### 2.2 数据与 Git

- `v001_create_catalog_core` 已发布，永久不改；
- 新 schema 按最早使用切片追加 migration，已通过的 migration 以后同样不可原地修改；
- 不 reset、checkout、stash、clean、amend、squash 或改写批准历史；
- 默认只做本地 commit，不 push；
- Codex 文档提交与 Cursor 实现提交必须分开。

### 2.3 真实照片与日志

- 自动化、构建、预览和运行 smoke 不得读取或遍历 `/Volumes/HDD2`；
- `.photoslibrary` 在阶段 1 始终禁止直接遍历；
- fixture 必须由测试在临时目录创建并可安全删除；
- 日志、Job payload/checkpoint 和测试证据不得包含 bookmark、完整绝对路径、图片内容或逐文件名称清单；
- `last_error_message` 只保存安全摘要，错误分类使用封闭 safe code。

## 3. 阶段 1 切片顺序

切片 1～4 保持原批准含义。项目所有者随后要求优先形成可运行 App，非阻塞的 watcher、活动控制和完备验证允许延后；切片 5 起改按
[`STAGE-1-ACCELERATED-DELIVERY.md`](./STAGE-1-ACCELERATED-DELIVERY.md) 执行。下表原切片 5～8 作为历史规划保留，不再是当前实施顺序。

| 切片 | 唯一目标 | 停止位置 |
|---|---|---|
| 1 | `v002` 查询支持、图库读模型与人工标签事务 | 不改权限、不读文件、不做 UI |
| 2 | 只读目录授权、bookmark 生命周期、Source 创建/停用/重新授权 | 不枚举子树、不做对账 |
| 3 | 流式枚举、媒体分类、lease-bound 批次与 generation 完成 | 不生成缩略图、不接 FSEvents |
| 4 | `v003` 缓存目录表、Image I/O 派生、配额与原子发布 | 不做 watcher 或产品网格 |
| 5 | FSEvents dirty trigger、Source/Job 活动 projection 与控制 | 不做完整产品界面 |
| 6 | 原生三栏壳、空状态、Sidebar、统一网格与单图查看 | 不做完整标签/筛选/命令面板 |
| 7 | Inspector 标签、批量 Undo、搜索筛选、活动入口与 `Command-K` | 不做 AI/Photos/自动化 |
| 8 | 阶段集成、无障碍、性能/故障 gate 与合成端到端验收 | 不做真实数据 smoke，除非另行授权 |

每个切片必须使用新的 Cursor CLI session。只有同一切片未通过 Codex 复审的窄范围返修才可恢复该 session。

## 4. 切片 1：目录库查询与人工标签基础

### 4.1 目的

在不接触用户文件与界面的前提下，先冻结产品界面依赖的数据语义：

- current Asset 的稳定分页；
- 统一图库与组合筛选；
- 网格轻量 projection 与 Inspector 详情 projection；
- 标签目录、选择聚合和原子批量决定；
- 创建标签并应用的一次事务；
- 一次会话内单级 Undo 所需的前态快照。

### 4.2 追加 migration v002

migration ID 固定为：

```text
v002_add_stage_1_catalog_query_support
```

`CatalogMigrationID.knownOrdered` 的顺序固定为 v001、v002。v002 只能做以下变化：

#### Asset 新列

| 列 | SQLite 类型 | null | 约束与语义 |
|---|---|---:|---|
| `file_name` | `TEXT` | 是 | file locator 的叶名称；不得为空、`.`、`..`，不得含 `/` 或 NUL；Photos 与阶段 0 旧行允许为空 |

`file_name` 只是 current locator 的查询派生值，不是资产身份。阶段 1 扫描写入 file Asset 时必须提供真实叶名称；v002 不猜测或重写既有 `relative_path`。

#### 新索引

| 名称 | key | partial predicate | 用途 |
|---|---|---|---|
| `asset_current_time_idx` | “时间为空”标记、`coalesce(media_created_at_ms, media_modified_at_ms)`、`id` | `locator_state = 'current'` | 全部照片最新/最早 keyset |
| `asset_current_source_time_idx` | `source_id`、同一时间键、`id` | `locator_state = 'current'` | 单/多来源查询 |
| `asset_current_file_name_idx` | `file_name COLLATE NOCASE`、`id` | current file 且 `file_name IS NOT NULL` | 文件名升序 keyset |
| `asset_generation_missing_idx` | `source_id, last_seen_generation, id` | current file | generation 完成时的 missing 集合 |
| `file_fingerprint_resource_id_idx` | `resource_id, asset_id` | `resource_id IS NOT NULL` | 同 Source 移动候选查询的前置索引 |
| `file_fingerprint_sha256_idx` | `sha256, asset_id` | `sha256 IS NOT NULL` | 后续显式歧义消解的前置索引 |

时间为空标记固定为：有 `media_created_at_ms` 或 `media_modified_at_ms` 时为 0，两者都为空时为 1。所有排序中未知时间放在已知时间之后。索引可以使用等价 SQLite expression，但 schema introspection 测试必须锁定最终表达式和 partial predicate。

v002 不创建 cache、FTS、prediction、smart collection、undo history、automation 或 Photos 表，也不修改任何 v001 表定义。若 SQLite 要求表重建才能满足实现者额外设想，必须停止；本切片不授权表重建。

### 4.3 Application 查询契约

生产命名可遵循现有风格，但必须提供不含 GRDB 类型的等价端口。

#### 页面请求

```text
AssetPageRequest
  filter
  sort: newest | oldest | fileNameAscending
  cursor: 与 sort 强绑定的 opaque value 或 nil
  limit: 1...200
```

`filter` 支持：

- 零或多个 `source_id`，多个来源之间为 OR；
- 零或多个“具体 tag_id + accepted/rejected”条件；
- 标签组合 `all` 或 `any`，默认由上层传 `all`；
- 零或多个 `availability`；
- 零或多个规范 media UTI；
- `tagPresence = any | tagged | untagged`；其中 tagged 表示至少一个 accepted 决定，untagged 表示 accepted 数为 0，rejected 不把照片变成“已有标签”；
- 本地 search text。

search text 先做 Unicode White_Space 首尾 trim；空串等同无搜索。非空搜索覆盖：file name、relative path、Source display name、与 Asset 存在人工决定关系的 Tag display name。SQL 通配字符 `%`、`_` 与 escape 字符必须按字面量转义；不得把用户输入拼接为 SQL。阶段 1 路径/来源搜索接受 SQLite `NOCASE` 的 ASCII 大小写语义；Tag 仍以已批准的 Domain normalization 为准，不在本切片引入自定义 SQLite collation。

默认只返回 `locator_state = current`，但不因 Source `disabled`、`unavailable` 或 `authorizationRequired` 排除 Asset；这些状态必须出现在 projection 中。historical locator 不进入普通图库。

#### 排序与 cursor

| sort | 顺序 |
|---|---|
| `newest` | 时间非空优先；时间倒序；`asset_id` 倒序 |
| `oldest` | 时间非空优先；时间正序；`asset_id` 正序 |
| `fileNameAscending` | file name 非空优先；`NOCASE` 正序；`asset_id` 正序 |

时间值固定为 `media_created_at_ms ?? media_modified_at_ms`。cursor 必须携带完成下一页比较所需的排序值与 `asset_id`，并拒绝用于另一 sort。不得使用 `OFFSET`。相同时间、相同大小写折叠文件名、未知时间和页间新增无关记录时，已有结果不得在连续页面中重复；测试固定数据库快照下不得跳项。

#### projection

网格轻量 projection 至少包含：

- asset/source ID；
- Source display name 与 state；
- relative path、file name；
- media UTI、媒体时间、像素尺寸；
- availability、content revision；
- accepted 与 rejected 人工决定数量；
- 下一页 cursor 由 page 返回，不嵌入单项。

Inspector 详情另行按单一 asset ID 查询，补充 fingerprint 的 size/mtime 与完整人工标签状态；本切片只有既有 `availability`，不提前新增 per-asset 详细错误列，也没有缩略图 URL、bookmark 或绝对路径。不存在的 ID 返回结构化 `notFound`，不能伪造空 projection。

### 4.4 标签查询与命令契约

#### 标签目录和选择聚合

- 默认列出 active Tag，按 `normalized_name COLLATE BINARY, id` 稳定排序；
- 可显式请求 archived Tag，但 archived 不能接受新决定；
- 对一个非空选择集合，按 Tag 返回 `acceptedCount`、`rejectedCount` 与 `unknownCount`；三者之和必须等于选择去重后的 Asset 数；
- 输入 asset IDs 必须存在，否则整体失败，不返回部分聚合。

#### 原子命令

必须支持：

1. 创建 Tag；
2. 对最多 10,000 个去重 asset IDs 批量 accepted；
3. 对最多 10,000 个去重 asset IDs 批量 rejected；
4. 对最多 10,000 个去重 asset IDs 清除某 Tag 决定；
5. “创建 Tag 并对选择应用决定”单事务；
6. 从成功命令返回的前态快照恢复一次。

所有命令先验证 Tag active、全部 Asset 存在、集合非空且未超上限，再在一个数据库写事务内执行。实现可在同一事务内分块，不能因 SQLite bind limit 把业务操作拆成多次提交。任何一行失败，Tag 创建、所有决定和前态恢复全部回滚。

Domain `TagNameNormalizer`、`TagCatalogRules` 与 `TagDecisionRules` 是唯一名称/状态规则；Infrastructure 不复制另一套 normalization。`normalized_name` 的 BINARY unique 继续作为并发最终防线。

Undo 是阶段 1 的会话级单级能力：成功批量命令返回每个 Asset 的前态；切片 7 的 Application presentation 只保留最近一次成功标签变更，任何后续标签写入使旧 Undo 失效。Undo 不跨 App 重启，不增加持久化历史表；恢复本身必须是单事务。切片 1 只交付无状态的前态/恢复端口，不建立 token registry，也不组装 UI 菜单。

### 4.5 切片 1 错误语义

至少区分以下不含用户数据的错误：

- invalid page limit / cursor sort mismatch；
- asset/tag not found；
- empty selection / selection too large；
- archived tag；
- duplicate normalized tag；
- invalid tag name；
- persistence failure。

错误字符串不得包含搜索词、relative path、文件名列表、SQL 或 bookmark。

### 4.6 切片 1 测试矩阵

#### Migration 与 schema

- fresh DB 按 v001→v002 各应用一次，重开幂等；
- 真实 v001 文件库带 sentinel 事实升级后事实保留；
- future migration 仍在任何新 migration 前拒绝；
- `file_name` 合法/空/`.`/`..`/slash/NUL 反例；
- 六个命名索引使用真实 `sqlite_schema`、`index_xinfo` 与 partial predicate introspection；
- v001 DDL 的原始 schema 文本没有变化；
- snapshot/startup 现有 migration-prefix 测试更新为 v001、v002，不弱化 future-schema gate。

#### 查询

- current/historical 分离；disabled/unavailable/authorizationRequired 来源资产仍保留；
- source、availability、UTI、tag presence 正反筛选；
- accepted/rejected 绑定具体 Tag；ALL/ANY 结果；
- search 覆盖四个字段并证明 `%`、`_`、escape 字面匹配且无 SQL 拼接；
- newest/oldest/name 三种排序，覆盖相同 key、未知时间、大小写折叠同名；
- 多页完整遍历无重复/跳项，cursor 与另一 sort 混用被拒绝；
- limit 0、201 被拒绝；
- Inspector 不存在 ID 被拒绝且不泄漏数据库细节。

#### 标签事务

- Unicode 名称规则和并发 normalized collision；
- accepted/rejected/clear 的单项与多项；
- mixed selection 三计数相加等于选择数；
- archived Tag、缺失 Asset、超上限、重复 Tag 时零部分写入；
- create-and-apply 后段 SQL 失败时 Tag 与决定一起回滚；
- 分块跨越数据库 bind limit 仍是单事务；
- 前态恢复精确还原 unknown/accepted/rejected 混合状态；UI 级旧 Undo 失效留到切片 7 验收。

#### 回归与依赖

- 运行全部既有 tests 与 Debug build；
- Swift 6 language mode 不回退；
- Domain/Application 不导入 GRDB；App/SwiftUI 不依赖具体数据库类型；
- target、scheme、entitlement、Package.resolved、`foundationReady`/`CatalogReady` 启动语义不变；
- 无 `/Volumes/HDD2` I/O，无 App 用户容器 I/O。

### 4.7 切片 1 停止门

完成切片 1 后必须停止。不得：

- 增加 read-only entitlement 或 privacy manifest；
- 打开 NSOpenPanel、创建/解析 bookmark、枚举目录；
- 加入 Image I/O、FSEvents、缩略图或缓存文件；
- 修改 SwiftUI、Composition Root、Job scheduler 或启动 gate；
- 创建 v003 或提前实现切片 2+ 占位。

## 5. 切片 2～8 的稳定契约

本节只约束后续交接单不能重新解释的边界；每个切片开工前仍须由 Codex生成精确 handoff。

### 5.1 切片 2：Source 授权

- entitlement 只新增 `user-selected.read-only` 与 app-scope bookmark；
- 用户动作前不弹系统选择器；
- 本切片只交付授权引擎与 AppKit 单目录选择器适配；现有 SwiftUI 默认不变，批准的“连接文件夹…”入口到切片 6 才接入；
- 根必须是可读目录且非 symlink、alias、package、`.photoslibrary`；
- 相同、祖先、后代 Source 均拒绝；无法证明不重叠时保守失败；
- bookmark、Source、初始 `folder.reconcile.v1` Job 单事务发布；
- scope start/stop 所有路径严格配对；stale bookmark 只有新 bookmark 成功后替换；
- 停用 Source 与其 reconcile Job 控制原子更新；重新授权只有自动证明同一根时沿用原 `source_id`；
- 停用/失权/离线保留 Asset、locator 和人工标签。

切片 2 的精确端口、Job payload、AppKit 配置、重授权身份、失败回滚与测试矩阵以
[`CURSOR-STAGE-1-SLICE-2-HANDOFF.md`](./CURSOR-STAGE-1-SLICE-2-HANDOFF.md) 为准。

> 当前状态说明：上述 entitlement 条目冻结的是阶段 1 切片 2 的交付边界。阶段 4 可移植导出后来要求
> 向用户选择的目录写入数据包，production target 因此改用 app-wide `user-selected.read-write`。来源
> bookmark 仍显式包含 `.securityScopeAllowOnlyReadAccess`；导出写 scope 不持久化，并在写入前拒绝与
> 任一已记录文件夹来源相同、互为祖先/后代或关系无法确认的目标。当前安全契约及证据见阶段 4 实施
> 规格第 13 节，不得把全局 entitlement 变化解释为允许写入来源树。

### 5.2 切片 3：对账

- streaming enumerator，批次建议上限 256；
- 跳过 hidden、package descendants、任何 `.photoslibrary`、symlink、alias 与特殊文件；
- relative path 非空、相对、规范且不能含 `.`/`..`/NUL/逃逸；
- 支持格式由 UTI + Image I/O 双重确认，扩展名只作候选过滤；
- Asset/fingerprint/last seen 与 Job checkpoint/lease/progress 单事务；
- 只有完整 generation 最终事务判 missing；dirty epoch 变化同事务排 successor；
- 崩溃重跑同 generation 幂等；lease 过期不能继续写。

切片 3 的精确 checkpoint、枚举批次、媒体分类、资产身份、lease 续租、generation 事务、隐私清单与测试矩阵以
[`CURSOR-STAGE-1-SLICE-3-HANDOFF.md`](./CURSOR-STAGE-1-SLICE-3-HANDOFF.md) 为准。

### 5.3 切片 4：缩略图缓存

固定 variant：

| raw value | 结果 |
|---|---|
| `gridSmall` | 256×256 px，视觉居中 aspect-fill |
| `gridRegular` | 512×512 px，视觉居中 aspect-fill |
| `preview` | 最大边 2048 px，保留比例 aspect-fit |

cache key 至少包含 asset ID、content revision、representation version、variant。生成前后 fingerprint 变化必须丢弃临时文件。配额为 20 GiB，磁盘安全余量为 `max(5 GiB, 目标卷容量 5%)`；只清理 ImageAll Caches 内经规范路径验证的派生文件。交互式网格/Inspector 请求可以显式选择“持久缓存优先、空间不足时仅内存返回”；该路径不得写 cache entry、object 或 staging，默认请求仍要求持久化并保持原空间不足合同。cache-entry schema 由切片 4 的 v003 交接单精确定义。

### 5.4 切片 5：FSEvents 与活动

> 延后：不阻塞首个“连接—扫描—浏览”产品闭环，转入加速计划技术债。

- watcher 先建立，再启动 reconcile；每次 App 启动都排一次 reconcile；
- FSEvents 只推进 dirty epoch 和合并 Job，不直接写 Asset；
- dropped/wrap/MustScanSubDirs 统一完整重扫；rootChanged/unmount 变 unavailable；
- pause/cancel/retry 只使用阶段 0 已批准状态机的合法边界；
- 活动 projection 只含聚合阶段、数量、时长、安全错误码和真实可用控制。

### 5.5 切片 6～7：产品界面

- 启动默认全部照片，只有当前真实功能入口；
- Sidebar/Content/Inspector 可折叠，窄窗口先隐藏 Inspector；
- 网格必须分页，不把全库放进 SwiftUI state；
- 标准 macOS 选择、Space 单图查看、Escape 返回；
- Inspector 是单选/多选标签主工作面；清除不等于拒绝；
- Filter Chips 多标签默认 ALL，可切 ANY；
- `Command-K` 只聚合已实现动作；
- 颜色不是状态唯一载体，VoiceOver、键盘焦点、Reduce Motion 和 Light/Dark Mode 进入验收。

### 5.6 切片 8：阶段验收

- 使用测试生成的多层临时 fixture 完成连接、首扫、重扫、改动、离线、失权、损坏、低空间与重启恢复；
- 运行期 source write spy 必须为零；
- 10,000 合成资产的查询与滚动基准只作为阶段内回归门，不宣称 100 万性能；
- 受保护真实年份目录与 Photos Library 均不进入本切片，除非项目所有者另行给出明确路径、动作和只读 smoke 授权。

## 6. 每个 Cursor 切片的统一验收证据

每次交付必须包含：

1. 全新 session ID 与 `system/init.model = Composer 2.5 Fast`；
2. 精确开工 HEAD、交付 commit、分支和最终工作区；
3. TDD 红灯→绿灯摘要；
4. 完整 Debug test 命令、exit code、从 `.xcresult` 或测试输出得到的准确总数；
5. Debug build、`git diff --check`；
6. 生产依赖方向和越界检查；
7. `/Volumes/HDD2` 零访问声明；
8. Cursor 作者、主题前缀与 `Agent-Role: implementation` trailer；
9. 明确停止位置、未实现的下一切片能力和是否 push；
10. `.cursor/rules/codex-review-handoff.mdc` 要求的中文复审材料。

任何测试失败、工作区来源不明、模型不符、需要改变批准 migration/产品语义或可能触碰真实照片时，Cursor 必须停止并报告，不得自行扩大权限。

## 7. Reader 检查问题

实施者在开工前应能只凭本文与当次 handoff 正确回答：

1. 为什么切片 1 不能加入 bookmark 或网格 UI？
2. disabled Source 的 current Asset 是否仍在统一图库？
3. 多标签筛选中 accepted/rejected 如何绑定具体 Tag，ALL/ANY 如何解释？
4. 为什么标签批量命令可以分块执行但不能分事务提交？
5. v002 是否允许创建缓存表或修改 v001？
6. 未知时间在 newest/oldest 中放哪里，cursor 如何避免 OFFSET？
7. 哪些真实路径在所有自动化中都禁止访问？
8. 何时才允许恢复上一 Cursor session？

若答案无法从文档唯一推出，必须在实现前向 Codex 报告规格缺口。
