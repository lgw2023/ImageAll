# ImageAll 阶段 1 / 切片 2 Cursor 实施交接单

> 状态：Ready for implementation<br>
> 日期：2026-07-15<br>
> 实施者：Cursor CLI，仅 `Composer 2.5 Fast`<br>
> 产品与架构评审：Codex<br>
> 上一批准实现：阶段 1 / 切片 1 `main@81c35e7444eed58695581b1947ee7f0ec3b9a254`<br>
> Cursor 开工 HEAD：由调用任务中的 `<LAUNCH_HEAD>` 替换为包含本交接单的精确 Codex 文档 commit<br>
> 本轮唯一范围：只读目录授权引擎、security-scoped bookmark 生命周期、Source 创建/停用/重新授权、AppKit 单目录选择器适配

## 1. 开工结论与停止位置

阶段 1 / 切片 1 已通过 Codex 验收。项目所有者批准切片 2 只实现授权引擎与 AppKit 选择器适配；如果平台适配确实需要，可以对现有 SwiftUI 做最小修改，但批准的“连接文件夹…”产品入口必须到切片 6 才接入。

本切片交付后必须停止。不得枚举所选目录的子项，不得读取图片，不得实现 reconcile handler、调度器、缩略图、FSEvents 或产品界面。自动化不得打开真实系统面板，也不得访问 `/Volumes/HDD2`。

## 2. 开工门与文档优先级

Cursor 开工前必须按顺序完整读取：

1. [`AGENTS.md`](../AGENTS.md)；
2. 本交接单；
3. [`STAGE-1-IMPLEMENTATION-SPEC.md`](./STAGE-1-IMPLEMENTATION-SPEC.md)，重点第 1～3、5.1、6 节；
4. [`STAGE-1-BACKEND-ARCHITECTURE.md`](./STAGE-1-BACKEND-ARCHITECTURE.md)，重点第 3～5、9.1、13 节；
5. [`STAGE-1-PRODUCT-UI-SPEC.md`](./STAGE-1-PRODUCT-UI-SPEC.md)，只用于继承 UI-003 的“用户动作前不弹面板”和术语，不实现界面；
6. [`STAGE-0-IMPLEMENTATION-SPEC.md`](./STAGE-0-IMPLEMENTATION-SPEC.md) 与当前 Source/Job/数据库代码，只继承已批准 schema 和状态机；
7. [`.cursor/rules/codex-review-handoff.mdc`](../.cursor/rules/codex-review-handoff.mdc)；
8. [`LOCAL-TEST-DATA-SAFETY.md`](./LOCAL-TEST-DATA-SAFETY.md)。

若本交接单与阶段规格实质冲突，停止并报告，不得自行解释。

开工必须证明：

- 使用全新 Cursor session，禁止 `--resume`、Cursor 子代理和 MCP；
- `system/init.model = Composer 2.5 Fast`；
- 当前为本地 `main`，HEAD 精确等于 `<LAUNCH_HEAD>`；
- 工作区除项目所有者已有未跟踪 `user/` 外无其他变化；不得读取、修改、暂存或提交 `user/`；
- 不得 reset、checkout、stash、clean、amend、push 或改写历史；
- 不访问或遍历 `/Volumes/HDD2`，不读取真实 App 容器。

## 3. 分层与端口契约

### 3.1 UI 面向端口

Application 层定义不含 AppKit、GRDB、`URL`、bookmark BLOB 或绝对路径的异步命令端口，语义至少覆盖：

- 请求连接一个文件夹；结果是 `cancelled` 或带 `sourceID` 的 `connected`；
- 请求为一个既有 folder Source 重新授权；结果是 `cancelled` 或带同一 `sourceID` 的 `reauthorized`；
- 停用一个既有 folder Source；成功返回该 `sourceID` 与 `disabled` 状态。

公开错误必须是封闭、`Sendable`、不含用户数据的 Application 值，至少能区分：Source 不存在、Source kind 不符、当前状态不允许、根对象无效或不可读、来源重叠、无法证明不重叠、身份不匹配、无法证明身份、bookmark 创建失败、授权不可用与持久化失败。不得透出 AppKit、Foundation、GRDB、SQLite、完整路径、display name、bookmark 或底层错误文本。

### 3.2 平台与基础设施边界

- AppKit 只存在于单目录选择器适配器；Application/Domain 不导入 AppKit；
- security-scoped `URL` 只在 AppKit/Foundation/Infrastructure 内短暂流动，不进入 Application 值、数据库 Job payload、日志或 View；
- 授权协调器实现 Application 端口，并组合选择器、根验证、bookmark 适配器与 GRDB 持久化；
- 供切片 3 使用的“在有界 security scope 内执行 Foundation 文件操作”能力保持 Infrastructure 内部，不提前暴露目录枚举端口；
- View 仍不得直接调用选择器、文件系统、bookmark 或数据库。

当前 `RootView`、Composition Root、启动 token 与视觉层无需改变。若实现者认为必须修改 SwiftUI/App 代码，只允许不产生可见入口、不触发面板、不改变现有展示语义的最小编译或注入接缝，并必须在交回材料逐行说明必要性；能不改则不改。

## 4. AppKit 单目录选择器

真实适配器必须：

- 只能由明确调用命令触发，初始化、App 启动和测试发现阶段都不能弹出面板；
- 使用 `NSOpenPanel`，只允许目录、禁止文件、禁止多选；
- `resolvesAliases = false`，让 alias 作为原对象交给根验证拒绝，不能静默跟随；
- `treatsFilePackagesAsDirectories = false`，不能把 package 当作普通目录进入；
- 不允许通过面板创建目录；不设置自动指向真实测试数据的默认目录；
- 用户取消是正常 `cancelled` 结果，不能创建 Source/Job，也不能变成错误；
- 自动化通过可注入 fake/spy 验证配置和触发次数，禁止真正显示系统面板。

Apple 说明 Open panel 返回的 URL 已获得隐式 security-scoped access。对每个成功返回的 URL，无论后续验证、bookmark 创建、重叠判断或数据库写入成功失败，协调器都必须在有界处理结束时调用一次 `stopAccessingSecurityScopedResource()`；不得再无条件增加一次显式 start 造成计数失衡。

参考：

- [Apple: NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel)
- [Apple: resolvesAliases](https://developer.apple.com/documentation/appkit/nsopenpanel/resolvesaliases)
- [Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)

## 5. entitlement 与签名

生产 App target 的 entitlements 在现有 `com.apple.security.app-sandbox = true` 之外只新增：

- `com.apple.security.files.user-selected.read-only = true`；
- `com.apple.security.files.bookmarks.app-scope = true`。

禁止新增 `user-selected.read-write`、Pictures、Downloads、全盘、网络、Photos、Automation、App Group 或其他能力。切片 2 不读取文件时间戳或磁盘空间，因此不创建 `PrivacyInfo.xcprivacy`。

必须同时检查：

1. 源 entitlements 文件只有上述三项；
2. Debug App 的实际签名包含三项和工具链允许注入的 `get-task-allow`，且不含 read-write；
3. `ARCHS`/destination 仍为批准的 Apple Silicon 路径，Deployment Target 仍为 macOS 15.0；
4. target、scheme、GRDB/`Package.resolved` 无无关变化。

参考：

- [Apple: user-selected read-only entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.files.user-selected.read-only)
- [Apple: app-scoped bookmarks](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access)

## 6. 根目录验证与重叠规则

### 6.1 新选择根验证

只读取根对象本身的 resource values，不列出或枚举任何子项。根必须：

- 当前存在、可读且是目录；
- 不是普通文件、symlink、Finder alias、package；
- 最后扩展名按 ASCII 大小写不敏感比较时不是 `photoslibrary`，即使系统未报告 package 也拒绝；
- 能取得非空、无路径信息的展示名；展示名只是 UI 元数据，不参与身份或权限判断。

测试必须覆盖真实临时目录/文件/symlink/package/假 `.photoslibrary`，并用平台 seam 固定 alias 与 unreadable 分支。测试不能靠访问真实目录制造权限失败。

### 6.2 重叠判断

新增 Source 前，对数据库内全部 folder Source（包括 disabled、unavailable、authorizationRequired）逐一判断：

- 同一根、既有根是新根祖先、新根是既有根祖先，均拒绝且数据库零变化；
- 必须使用已授权、已解析 URL 的文件系统关系/资源身份判断，不能只比较字符串路径、display name、bookmark bytes 或大小写折叠路径；
- 若任一既有 folder Source 的 bookmark 无法在不弹 UI、不自动挂载的条件下解析并取得足够关系证据，本次新增以 `overlapIndeterminate` 保守失败；
- 所有临时 scope 在成功、拒绝和异常路径都释放。

## 7. bookmark 创建、解析与有界访问

### 7.1 创建

对通过根验证的选择 URL 创建 app-scoped bookmark，creation options 必须同时包含：

- `withSecurityScope`；
- `securityScopeAllowOnlyReadAccess`。

bookmark 可以嵌入根的 file resource identifier 与 volume identifier 作为同机、best-effort 的重新授权提示；Apple 明确说明这两个 identifier 不跨系统重启持久，因此它们不能单独证明重新授权身份，不增加 schema 列。bookmark 创建失败时不写 Source 或 Job。

### 7.2 解析与访问

解析已持久化 bookmark 时必须使用：

- `withSecurityScope`；
- `withoutUI`；
- `withoutMounting`；
- `withoutImplicitStartAccessing`，随后由实现显式取得 scope。

显式 `startAccessingSecurityScopedResource()` 返回 true 后，必须用确定性 `defer`/等价结构在所有成功、验证失败、业务 closure 抛错和刷新失败路径调用一次 stop；start 返回 false 时不得调用 stop，也不得执行受保护操作。

取得 scope 后重新验证根对象，但仍不得枚举子树。Infrastructure 内部 access closure 可以接收临时 URL；该 URL 不得逸出 closure、缓存到 Application state 或持久化。

### 7.3 stale bookmark

- stale 解析成功且 scope 可取得时，先从当前 resolved URL 创建新的只读 app-scoped bookmark；
- 只有新 bookmark 创建成功且数据库替换成功后，旧 BLOB 才能被替换；
- 新 bookmark 创建失败时，旧 BLOB 保持逐字节不变，Source 转为 `authorizationRequired`；
- 数据库替换失败时事务回滚，旧 BLOB/Source state 保持原值并返回 `persistenceFailure`；
- 不得先清空 bookmark，也不得因 stale 创建第二个 Source。

### 7.4 状态映射

| 观察结果 | Source state | 结果 |
|---|---|---|
| bookmark、scope、根验证全部成功 | `active` | 允许有界 access closure |
| 根或所在卷暂时不存在，且证据可明确归类为离线 | `unavailable` | 不执行 closure，保留全部事实 |
| bookmark 无法授权解析、scope 被拒绝、根变为不可读/非法、stale 刷新失败 | `authorizationRequired` | 不执行 closure，保留全部事实 |
| Source 已由用户停用 | `disabled` | 不解析、不启动 scope、不执行 closure |

底层错误无法可靠区分离线与失权时，按 `authorizationRequired` 保守处理。状态写入失败返回 `persistenceFailure`，不得伪称状态已经持久化。

上表约束的是对某一 Source 发起的普通业务访问。第 6.2 节在用户新建来源时执行的全目录重叠审计是唯一例外：它可以对 disabled Source 临时解析 bookmark、取得根对象关系后立即释放 scope，但仍不能枚举或执行任何业务 access closure。否则无法同时满足“disabled 不可使用”与“disabled 根仍参与重叠排除”。

## 8. Source 与初始 Job 的原子发布

新连接成功时，在同一个 `DatabasePool.write` 事务中发布：

1. 一个新的 folder Source：新 UUID、非空 display name、bookmark BLOB、`active`、generation/dirty epoch 维持 v001 默认值；
2. 一个新的 pending Job，契约固定为：

| 字段 | 值 |
|---|---|
| `kind` | `folder.reconcile.v1` |
| `payload_version` | `1` |
| `payload` | UTF-8 JSON object，只含 `contract_version = 1` 与小写 `source_id` |
| `source_id` | 与新 Source ID 相同 |
| `coalescing_key` | `folder.reconcile.v1:<lowercase-source-uuid>` |
| `priority` | `0` |
| `attempts` / `max_attempts` | `0` / `5` |
| `not_before_ms` | 与事务使用的当前时钟值相同 |
| 初始状态 | `pending`、control `none`、progress `0/null`、无 lease/checkpoint/error |

JSON 测试比较解码后的精确 key 集和值，不依赖编码器 key 顺序；payload、日志与错误中禁止出现 bookmark、display name 或路径。

Source INSERT 后、Job INSERT 前的故障必须证明两者都不残留。不得先调用现有 `JobQueue.enqueue` 形成第二个事务；可以提取/复用同一 GRDB transaction 内的最小 Job INSERT helper，但不能改变阶段 0 Job 的公共语义。

本切片不执行该 Job，不注册 reconcile handler，不 claim Job，也不枚举目录。

## 9. 停用与重新授权

### 9.1 停用

停用仅适用于 folder Source，且幂等。一个 GRDB 事务内必须：

- 将 Source state 写为 `disabled` 并更新 `updated_at_ms`；
- 对该 Source 的 `folder.reconcile.v1` 活跃 Job：pending/paused/retryableFailed 转为 cancelled；running 只把 control request 提升为 cancel；
- 保留 Job 记录，且不触碰其他 kind 或 terminal Job；
- 保留 Source、bookmark、Asset、current/historical locator、fingerprint、Tag 与人工决定，不递增 generation，不产生 missing。

任一后段 SQL 失败必须回滚 Source 和全部 Job 变化。不得删除 Source 或依赖级联删除证明保留语义。

### 9.2 重新授权

重新授权只允许 existing folder Source 处于 `unavailable` 或 `authorizationRequired`；active 与 disabled 均结构化拒绝。用户取消时零变化。

成功前必须：

1. 验证新选择根与创建新 bookmark；
2. 在新选择 URL 的临时授权仍有效时解析旧 bookmark，并用当前文件系统关系证明旧 resolved URL 与新根为 `same`；内嵌 root/volume identifier 只能作当前运行期的辅助交叉检查，不能单独作为跨重启证明；
3. 当前关系明确为不同对象则 `identityMismatch`；旧 bookmark 无法解析、关系查询失败或证据不唯一则 `identityIndeterminate`；二者都不能用路径字符串、display name、bookmark bytes 或用户确认替代；
4. 证明同一身份后，在一个事务替换 bookmark、更新展示名/时间、设为 active，并确保该 coalescing key 恰有一个活跃 reconcile Job：已有则复用，没有则按第 8 节插入；
5. 任一失败时旧 bookmark、state、display name 和 Job 集合逐项保持不变。

“无法自动证明但让用户确认沿用旧 Source”的界面与产品决策仍未批准；不得提前实现。

## 10. TDD 顺序与强制测试矩阵

按以下六簇逐簇红灯→最小绿灯，每簇至少记录一个修正前失败测试和原因：

1. entitlement、签名与 AppKit 面板配置；
2. 根验证、选择取消和隐式 selection scope 释放；
3. bookmark creation/resolution options、显式 scope 配对与 stale 刷新；
4. 重叠判断与 Source + 初始 Job 原子发布；
5. Source 状态映射、停用和重新授权事务；
6. 错误收敛、架构/范围检查与完整回归。

必须使用测试创建并登记的唯一临时目录和真实临时文件数据库。强制覆盖：

- 面板在命令前零触发、目录 only、single、alias 不解析、取消零写入；
- 合法根与 file/symlink/alias/package/`.photoslibrary`/unreadable 反例；
- bookmark 创建 options 与解析四 options；
- start true 的正常/closure 抛错/根验证失败/stale 失败路径 stop 各恰好一次，start false 为零；
- stale 刷新成功替换，创建失败和 SQL 替换失败旧 BLOB 不变；
- same、existing ancestor、new ancestor 拒绝，disjoint 接受，既有 bookmark 不可解析时保守拒绝；
- 原子发布成功精确一 Source/一 Job；Source 后故障、Job 约束故障均零半事实；payload 精确且不含敏感字段；
- unavailable/authorizationRequired/disabled/active 映射均不释放任何 locator 或人工标签；
- 停用对 pending/paused/retryableFailed/running/terminal Job 的精确效果和后段失败回滚；
- 重新授权 same 成功、mismatch/indeterminate/active/disabled/missing/wrong kind/cancel/SQL failure 反例；已有活跃 Job 复用，无活跃 Job 新建；
- Application 公共错误不泄漏 URL、路径、display name、bookmark、SQL 或底层错误；
- `Domain`/`Application` 无 AppKit/GRDB 导入，只有 AppKit adapter 导入 AppKit，SwiftUI 没有系统面板调用；
- 无目录子项枚举、Image I/O、FSEvents、Photos 或 `/Volumes/HDD2` 访问。

生产平台 API 难以在无交互测试宿主稳定制造的分支，必须通过窄 seam/fake 驱动；同时要有针对生产 adapter 配置/options 的静态或实例属性测试，不能只测试一套与生产无关的 fake。

## 11. 允许与禁止修改

允许：

- Application 中本切片所需的纯值、错误和端口；
- Infrastructure 中 AppKit 选择器、Foundation bookmark/root access 适配器与 GRDB Source 授权 repository；
- `ImageAll.entitlements` 与必要 Xcode 文件引用；
- 对应单元/临时文件数据库集成测试；
- 为同事务复用而对既有 Job persistence 做最小、行为不变的内部提取；
- 若无法避免，按第 3.2 节约束做零可见行为的最小 App/SwiftUI 接缝。

禁止：

- 修改任何已发布 migration、创建 v003、新表/列/索引或修改 `Package.resolved`；
- 接通或绘制“连接文件夹…”、来源 Sidebar、空状态、重授权 banner 或任何新产品 UI；
- 修改 `foundationReady`/`CatalogReady`、自动打开面板、组装扫描调度器；
- 子树枚举、媒体识别、读取图片/文件时间戳、hash、Image I/O、FSEvents、thumbnail/cache、PhotoKit、AI/自动化；
- 创建 `PrivacyInfo.xcprivacy`；
- 修改 Codex 文档、任务记录或 `user/`；
- 访问 `/Volumes/HDD2` 或真实 Application Support/Caches；
- push、amend、reset、checkout、stash、clean、history rewrite。

## 12. 验收与本地 commit

至少执行：

```bash
xcodebuild -scheme ImageAll -destination 'platform=macOS,arch=arm64' -configuration Debug test
xcodebuild -scheme ImageAll -destination 'platform=macOS,arch=arm64' -configuration Debug build
codesign -d --entitlements :- <Debug ImageAll.app>
git diff --check
```

从 `.xcresult` 或测试输出报告准确 passed/failed/skipped，不沿用旧测试总数。另需提供：

- `ImageAll.entitlements` 与实际签名的 entitlement 摘要；
- 生产变更中没有目录枚举、文件写入、Image I/O/FSEvents/PhotoKit 的静态检查；
- 测试只在其登记的临时根和临时数据库写入/清理；未访问受保护真实数据；
- Swift 6、macOS 15、arm64、target/scheme/GRDB 锁定无回退。

通过后创建一个窄范围本地 commit：

- author/committer：`Cursor Agent <cursoragent@cursor.com>`；
- subject：`feat(cursor): add read-only folder authorization`；
- trailer：`Agent-Role: implementation`；
- 不含 `Co-authored-by`，不提交 `user/`，不 push。

交付后停止并按 `.cursor/rules/codex-review-handoff.mdc` 输出中文复审材料，明确未进入切片 3 或切片 6 UI。

## 13. Codex 重点复审点

1. Application 是否完全看不到 AppKit、URL、bookmark、GRDB 与路径；
2. AppKit 面板是否只在显式命令触发，取消零写入，selection implicit scope 是否释放；
3. bookmark options、start/stop、stale 替换和状态映射是否在失败路径仍保守；
4. Source + 初始 Job、停用、重新授权是否是真实单事务且无半事实；
5. 重叠与重新授权身份是否使用文件系统证据而非路径字符串；
6. entitlement 是否只增加批准两项，是否无 UI、枚举、隐私清单和真实数据越界。
