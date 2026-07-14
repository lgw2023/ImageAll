# ImageAll Cursor 实施交接单：阶段 0 / 切片 2

> 状态：Ready for handoff<br>
> 日期：2026-07-14<br>
> 实施者：Cursor<br>
> 产品与架构评审：Codex<br>
> 本轮范围：纯 Domain 规则，不包含 GRDB、migration、Job 状态机或启动集成

## 1. 交接结论

Gate 0 与切片 1 已通过 Codex 复审。Cursor 现在获准实施阶段 0 的切片 2：建立不依赖 UI、GRDB 或其他基础设施的核心领域值、封闭词汇和规则，并用 Swift 6 单元测试固定其语义。

本轮结束后必须停止并交回评审。GRDB v001 是切片 3，不得提前开始；`foundationReady` 继续只表示应用空壳与依赖组装已启动，不能改名或升级为 `CatalogReady`。

## 2. 开工基线与文档优先级

Cursor 开始前必须完整阅读以下文件，优先级从高到低：

1. [`AGENTS.md`](../AGENTS.md)：角色、范围和修改纪律；
2. 本交接单：当前切片的执行范围、顺序和停止位置；
3. [`STAGE-0-IMPLEMENTATION-SPEC.md`](./STAGE-0-IMPLEMENTATION-SPEC.md)：阶段 0 的规范性领域契约，重点是第 3.2、4.1 通用词汇、4.2、5、8 和 9.2 节；
4. [`ARCHITECTURE.md`](./ARCHITECTURE.md)：上位系统边界和领域语义；
5. [`CURSOR-STAGE-0-HANDOFF.md`](./CURSOR-STAGE-0-HANDOFF.md)：只作为 Gate 0 与切片 1 的历史记录，不是当前任务。

若本交接单与阶段规格出现实质矛盾，Cursor 必须停止并报告，不得自行选择。实现便利性不能改变领域词汇、标签标准化顺序或人工决定优先原则。

批准的 Git 基线为：

| Commit | 含义 |
|---|---|
| `1051576` | 阶段 0 文档基线 |
| `869b3e0` | 切片 1：SwiftUI 空壳与 Composition Root |
| `01fbed6` | App 与测试 target 统一使用 Swift 6 language mode |

开工前必须证明当前历史包含 `01fbed6`、工作区干净且没有未说明的实现变更。若不满足，停止并返回差异，不得覆盖、清理或吸收他人的修改。

## 3. 本轮架构边界

### 3.1 允许创建的职责

只创建当前规则确实需要的 Domain 源文件与对应测试，例如：

```text
ImageAll/Domain/Models/
ImageAll/Domain/Rules/
ImageAllTests/Domain/
```

目录名不是新增抽象的许可。每个文件必须对应第 4 节的一项实际规则；不要预建空文件、空目录或未来协议。

Domain 可以依赖 Swift 标准库和 Foundation 的值类型、Unicode 能力，但必须满足：

- 不导入 SwiftUI、GRDB、AppKit、PhotoKit 或文件系统适配代码；
- 不知道数据库表、Column、Row、migration 或 Repository 实现；
- 不读取系统时钟、用户目录、bundle identifier 或环境状态；
- 不执行 I/O；
- 有跨并发边界意义的领域值采用值语义，并在合理处满足 `Equatable` 与 `Sendable`；
- 不为了未来持久化而提前加入 GRDB Record、数据库字段映射或无需求的 `Codable`。

本轮可以修改 Xcode 工程文件以纳入新增源文件和测试，但不得增加 target、scheme、Swift Package、entitlement 或构建脚本。

### 3.2 明确不做

本切片不得实现或占位：

- GRDB 依赖、`Package.resolved`、DatabaseQueue、DatabasePool 或任何 migration；
- `source`、`asset`、`tag`、`asset_tag_decision`、`job` 等数据库 Record；
- Catalog Repository、跨表校验或真实事务；
- Job 状态机、claim、lease、checkpoint、恢复或调度锁；
- AppPaths、Application Support 目录、备份或恢复；
- 文件夹扫描、PhotoKit、security-scoped bookmark、缩略图或预测；
- 新产品界面、`CatalogReady` 或对现有根窗口语义的改动。

## 4. 必须固定的领域契约

### 4.1 封闭词汇与不可变身份

Domain 中的封闭词汇必须与阶段规格完全一致，不能产生大小写、下划线或近义词变体：

| 概念 | 允许值 |
|---|---|
| Source kind | `folder`, `photos` |
| Source state | `active`, `disabled`, `unavailable`, `authorizationRequired` |
| Asset locator kind | `file`, `photos` |
| Asset locator state | `current`, `historical` |
| Asset availability | `available`, `missing`, `unreadable`, `unsupported` |
| Tag state | `active`, `archived` |
| 可持久化人工决定 | `accepted`, `rejected` |

`unavailable` 只属于 Source state；Asset 对应的是 `missing`、`unreadable` 或 `unsupported`，不得新增 Asset 的同名状态。总架构中的 `manualAccepted` / `manualRejected` 是产品层三态概念；本切片的可持久化决定词汇仍只能是 `accepted` / `rejected`。

Source、Asset 和 Tag 的 ID 创建后不可变化。使用 UUID 作为领域身份，但本切片不实现 UUID 文本的数据库编码校验；小写规范文本属于切片 3 的持久化边界。

只定义本切片规则实际使用的最小实体和值。不要复制整张未来数据库表，也不要把时间戳、bookmark、媒体尺寸等无关字段塞入领域模型。

### 4.2 Source 停用

停用 Source 的领域操作只把状态变成 `disabled`：

- 不返回或触发删除 Asset、标签决定、任务历史的动作；
- 重复停用按幂等成功处理，便于应用用例安全重试；
- 本切片不实现永久清除。

这里采用“幂等停用”作为切片级实施假设；若实现者认为它与既有契约冲突，必须在编码前报告。

### 4.3 Asset content revision

`content_revision` 的领域语义必须满足：

- 新 Asset 从 1 开始；
- 只接受严格大于当前值的新 revision；相等或更小都返回结构化的 revision 回退错误；
- revision 变化只表达来源内容发生变化，不改变 Asset ID；
- revision 变化不能删除、重置或改写人工决定。

本切片不创建特征、缩略图或预测模型；“使派生数据失效”只固定为以后应用服务必须消费的领域结果或语义，不建立阶段外表结构。

### 4.4 标签显示名与 normalized name

标签创建必须同时产生经过验证的显示名和 normalized name。

显示名规则：

- 按 Unicode `White_Space` 属性移除首尾空白；
- 保留内部字符、内部空白形式和用户大小写；
- trim 后为空则返回结构化 `invalidName`，不能创建 Tag。

normalized name 的顺序不可调整：

1. Unicode NFC；
2. 按 Unicode `White_Space` 属性 trim；
3. 把每段连续 Unicode `White_Space` 折叠为一个 ASCII space（U+0020）；
4. locale-independent default case fold；
5. 再次 Unicode NFC。

必须覆盖阶段规格中的四个向量：

| 输入 | normalized name |
|---|---|
| `"  家人  "` | `"家人"` |
| `"Work\t  Reference"` | `"work reference"` |
| composed `"Café"` | `"café"` |
| decomposed `"Cafe◌́"` | `"café"` |

再增加 `"Straße"` → `"strasse"`，用于证明实现执行 Unicode default case fold，而不是普通 lowercase。

另加边界测试证明：

- 非 ASCII Unicode White_Space 同样参与 trim 与折叠；
- NFC 不执行宽度折叠；
- normalized name 不去除音符或变音符号；
- 结果使用 normalized NFC UTF-8 的稳定二进制键比较，不使用本地化、二次大小写不敏感或搜索式比较。

同一 normalized name 只能存在一个 Tag。唯一性是集合级领域规则：候选名称与已有 normalized name 的二进制键精确相等时返回 `duplicateTag`。本切片不能用数据库唯一索引替代该测试；数据库第二层保护属于切片 3。

### 4.5 人工决定

必须在类型和规则上区分“业务查询状态”和“可持久化决定”：

- 可持久化决定只有 `accepted` 与 `rejected`；
- `unknown` 表示没有决定，必须由“缺少决定”表达，不能构造成将来可写入 `asset_tag_decision` 的记录；
- 同一 Asset/Tag 设置新决定时替换旧决定，不能同时持有 accepted 与 rejected；
- 清除决定回到 unknown，即返回无决定状态；
- 已归档 Tag 拒绝新的批量应用，返回 `invalidStateTransition`，并保持原有决定不变；
- 预测类型和预测写入不在本切片出现，因此不能通过预测路径生成或覆盖人工决定。

测试必须覆盖：unknown→accepted、unknown→rejected、accepted→rejected、rejected→accepted、任一已存在决定→unknown，以及归档 Tag 的批量应用被拒绝且输入状态未变。

### 4.6 generation 与 locator 身份规则

本切片只固定不执行 I/O 的纯规则，不实现扫描器或事务：

- 未完成的 generation 不具备把未见 Asset 标为 missing 的资格；
- 只有完整完成的 generation 才能产生“允许标记 missing”的领域判定；
- Source 暂时 unavailable 不能被解释为 generation 完成，也不能释放 current locator；
- 当前 locator 被证明仍是同一资源时保留原 Asset ID；
- 当前 locator 被证明已被不同资源复用时，领域结果必须是“旧 locator 转 historical，并创建不继承人工决定的新 Asset”；
- 资源身份无法确定时返回 `locatorConflict`，不能猜测复用或继承。

这里可以用最小的抽象判定输入表达 `same`、`different`、`indeterminate`，但不能提前引入 resource ID、SHA-256 计算、文件 URL 或 Repository。真正的同事务写入和 partial unique index 在切片 3 及后续来源实现中验证。

### 4.7 结构化错误

领域错误必须是可枚举、可比较的结构化语义，至少能区分：

- `invalidName`；
- `duplicateTag`；
- `invalidStateTransition`；
- `revisionRegression`；
- `locatorConflict`；
- `referenceNotFound`。

错误可以携带安全的领域上下文，但不能把面向用户的本地化文案、完整文件路径或自由文本作为唯一判别依据。`referenceNotFound` 本轮可以只作为共享错误词汇，不需要为了触发它而虚构 Repository。

## 5. TDD 实施顺序

遵循红—绿—整理，但不为了制造红灯而加入假生产逻辑。建议按以下可独立观察的行为簇推进：

1. 标签名称：先写非法空名、全部规定标准化向量和重复 normalized name 的失败测试，再写最少实现；
2. 人工决定：先写冲突不可并存、替换、清除和归档 Tag 批量拒绝测试，再写最少实现；
3. Asset 与 Source：先写 revision 回退、停用不产生删除、generation 未完成和 locator 不确定性测试，再写最少实现；
4. 结构化错误与封闭词汇：补齐精确比较和 Swift 6 `Sendable` 编译检查；
5. 运行全部测试和 Debug build，证明切片 1 没有回归。

至少保留前四个行为簇中各一个“目标代码已存在但行为仍错误”的红灯证据。仅以文件不存在、target 不编译或故意写 `XCTFail()` 作为红灯不算 TDD 证据。

测试应断言外部可观察行为和错误语义，不测试私有实现、文件数量或具体类型命名。每个测试使用独立数据，不访问用户容器，不依赖测试执行顺序。

## 6. 完成标准

本切片只有同时满足以下条件才可以申请评审：

- 第 4 节所有可执行规则有自动化测试；ID 不可变、禁止依赖和无 I/O 等结构约束由编译结果与代码评审证明；
- Domain 源文件不导入 UI、GRDB、PhotoKit 或基础设施；
- 没有新增 Swift Package、target、scheme、entitlement 或持久化文件；
- 现有 `foundationReady` 测试仍通过，根视图语义未变化；
- `ImageAllTests/Domain` 的目标测试和全套测试均通过；
- Debug build 成功，实际仍使用 Swift 6 language mode；
- `git diff --check` 无输出；
- 只创建一个独立本地切片 2 commit，完成后工作区干净；
- 不配置 remote、不 push；
- 完成后停止，未进入切片 3。

## 7. Cursor 必须回传的证据

实施报告必须至少包含：

1. 开工前 HEAD、分支和干净工作区证据；
2. 新增或修改文件清单，每个文件对应的领域职责；
3. 依赖方向检查：逐个列出 Domain 文件的 import，并证明没有 GRDB、SwiftUI、AppKit、PhotoKit 或 Infrastructure 依赖；
4. 前四个行为簇各自的红灯测试名称、失败原因和随后绿灯结果；
5. 四个规定标签向量、`Straße` case-fold 向量、Unicode 边界、决定转换、revision、generation 和 locator 规则的测试列表；
6. 全套 `xcodebuild test` 与 Debug build 的命令、退出码和结果摘要；
7. target、scheme、Swift Package 与 entitlement 是否发生变化；预期均无变化；
8. 切片 2 commit、`git status --short --branch` 与 `git diff --check` 结果；
9. 已知限制、未决问题、任何偏离或实现假设。

不要求窗口截图或新的启动证明，因为本切片没有 UI 行为变化。不得创建 `docs/STAGE-0-EVIDENCE.md`；阶段 0 全部切片完成后再统一汇总。

## 8. 交回 Codex 后的评审门

Codex 将只做架构和证据评审，不替 Cursor 修改代码。评审重点：

- 实现是否保持纯 Domain 边界；
- 领域词汇和标准化算法是否精确匹配规格；
- unknown 是否确实不能成为持久化决定；
- 人工决定、revision、generation 和 locator 身份是否有反例测试；
- 是否出现为切片 3–6 提前搭建的依赖或抽象；
- 测试是否证明行为，而不是绑定实现细节；
- 是否可以授权 Cursor 进入切片 3（GRDB v001）。

只有切片 2 评审通过，才生成切片 3 交接单。此时阶段 0 仍是“In implementation”，不能标记为“Completed”。
