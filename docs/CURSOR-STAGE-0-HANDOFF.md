# ImageAll Cursor 实施交接单：阶段 0 / 首轮

> 状态：Archived；Gate 0 与切片 1 已于 2026-07-14 通过 Codex 复审<br>
> 日期：2026-07-14  
> 实施者：Cursor  
> 产品与架构评审：Codex  
> 本轮范围：Gate 0 与实施切片 1，不包含切片 2–6

> 归档说明：本文件保留首轮开工条件与历史任务，不再作为当前 Cursor 指令。当前任务以最新的分切片交接单为准。

## 1. 交接结论

阶段 0 的架构与实施规格已经足够，不再继续扩写设计正文。下一步应由 Cursor 按本交接单建立可审查的工程基线；Codex 只评审范围、架构一致性和实施证据，不编写实现代码。

本轮采用小步交付：Cursor 只完成 Gate 0 和“SwiftUI 空壳与 Composition Root”。通过评审后，再单独领取领域规则、GRDB v001、任务状态机、快照恢复和启动集成任务。

## 2. 约束与文档优先级

Cursor 开始前必须完整阅读以下文件，优先级从高到低：

1. [`AGENTS.md`](../AGENTS.md)：角色、范围和修改纪律；
2. [`STAGE-0-IMPLEMENTATION-SPEC.md`](./STAGE-0-IMPLEMENTATION-SPEC.md)：阶段 0 的规范性契约；
3. [`ARCHITECTURE.md`](./ARCHITECTURE.md)：系统边界、阶段路线和 ADR。

若文档与实现便利性冲突，以规格为准。若两份规范互相矛盾，Cursor 必须停止并报告，不得自行选择或放宽约束。不得修改已决定的 ADR 来迁就实现。

本交接单只把阶段规格收窄为切片 1 的当前任务，不放宽阶段规格中的任何契约；全阶段架构与数据语义以规格为准，本轮执行顺序和停止位置以本交接单为准。

## 3. 当前已知开工门

本节是首轮实施前的历史快照，已经被实际 Gate 0 证据取代，不代表当前工具链或仓库状态。

2026-07-14 的只读复核结果：

- `xcodebuild -version` 失败，当前只配置 Command Line Tools；`/Applications` 下未发现 Xcode；
- Swift 为 6.3.2，目标为 arm64 macOS；
- 当前目录不是 Git 仓库；
- 正式 bundle identifier 尚未由项目所有者确认；
- 阶段 0 暂用 macOS 15.0、Apple Silicon 和本地开发签名；是否支持 Intel 与最终分发方式不在本轮冻结。

完整 Xcode 必须由项目所有者安装并选择。Cursor 不得自行下载安装 Xcode。正式 bundle identifier 必须由项目所有者明确提供，Cursor 不得猜测；它不属于 Gate 0，但会阻塞切片 1 开始。

## 4. Cursor 本轮任务

### 4.1 只读预检

先收集全部已知阻塞，不要只报告遇到的第一个：

1. 运行并记录 `xcode-select -p`、`xcodebuild -version`、`xcodebuild -showsdks`、`xcrun --find swift`、`xcrun swift --version`、macOS 版本和架构；
2. 证明所选 developer directory 属于完整 Xcode，`xcrun` 解析到该 Xcode，并且存在可支持 macOS 15.0 deployment target 的 macOS SDK；
3. 若 Xcode license、首次启动组件或 SDK 查询尚未就绪，视为 Xcode 门未通过；Cursor 不得自行以管理员权限修复；
4. 同时检查项目所有者是否已提供正式 bundle identifier。

如果 Xcode 门未通过，立即停止，不创建工程、不初始化 Git、不修改文件；一次性返回 `BLOCKED_GATE_0_XCODE`、原始错误摘要，以及同时发现的其他阻塞（例如 `BLOCKED_PRODUCT_INPUT_BUNDLE_ID`）。

### 4.2 Gate 0：Git 与工具链基线

只读预检中的 Xcode 门通过后：

1. 在当前目录初始化本地 Git 仓库；
2. 基线明确包含 `AGENTS.md`、`docs/ARCHITECTURE.md`、`docs/STAGE-0-IMPLEMENTATION-SPEC.md` 和 `docs/CURSOR-STAGE-0-HANDOFF.md`；
3. 添加最小 `.gitignore`，只排除 macOS/Xcode 个人状态和本地构建产物；不得预先忽略后续可复现构建所需的共享配置；
4. 若 Git 作者身份不可用，停止并请求项目所有者提供；不得猜测身份或修改全局 Git 配置；
5. 创建文档基线 commit，并证明工作区干净；
6. 不配置远程仓库，不 push，不增加与阶段 0 无关的工具配置。

Gate 0 的完成条件是：完整 Xcode 与 macOS SDK 可用、版本已记录、本地 Git 文档基线已提交且工作区干净。正式 bundle identifier 不是 Gate 0 条件。

### 4.3 切片 1 前的产品输入门

Gate 0 通过后，确认项目所有者已提供正式 bundle identifier。若仍未提供，停止并返回 `BLOCKED_PRODUCT_INPUT_BUNDLE_ID`；不得创建使用临时 identifier 的工程，也不得把切片 1 标记为开始或完成。

### 4.4 切片 1：SwiftUI 空壳与 Composition Root

本切片只应用阶段 0 规格中与切片 1 直接相关的条款：第 3.1 节的工程 target、生命周期、沙盒和 Composition Root 规则，第 3.2 节的依赖方向，第 8 节切片 1 行，以及第 9.1 节中不依赖数据库和 GRDB 的工程验收项。第 9.1 节的目录库创建和依赖锁定，以及第 9.2–9.5 节，全部推迟到相应后续切片。

只完成以下内容：

- 创建标准 SwiftUI macOS App，使用 `App` 生命周期和 `WindowGroup`；
- 只创建 `ImageAll` App target 与 `ImageAllTests` target；
- 创建并提交可供干净检出复现构建与测试的 shared scheme；个人 `xcuserdata` 不得提交；
- deployment target 使用暂定 macOS 15.0；Apple Silicon 是本轮验证环境，不得把 `ARCHS` 写死为 `arm64`，以免提前决定 Intel 产品范围；
- 使用项目所有者确认的正式 bundle identifier；
- 使用不依赖 Development Team 的本地运行签名；若 Xcode 无法以本地签名完成 Debug 构建和启动，则停止报告，不得猜测 Team；
- 启用 App Sandbox；项目声明的 entitlement 只能包含 App Sandbox，不申请网络、Photos、用户文件、iCloud、App Group、Automation 或其他阶段外能力；Debug 工具链自动注入的 `get-task-allow` 可以出现在最终签名中，但不得进入项目 entitlement 声明；
- 建立最小 Composition Root，由它构造一个不依赖基础设施的只读启动展示状态，再注入 SwiftUI 根视图；SwiftUI 不得直接构造或打开数据库；
- 只创建当前切片确有文件的目录，不预建未来层、不引入额外 module、XPC、LaunchAgent、UI Test target 或第三方依赖；
- 根窗口只显示产品名和一个语义明确的 `foundationReady` 状态，含义仅为“应用空壳与依赖组装已启动”；不得显示或定义 `CatalogReady`，不得暗示目录库、索引、标签、模型或恢复能力存在。

本切片不得实现 GRDB、migration、领域规则、任务队列、备份恢复、文件夹或 PhotoKit；这些属于后续独立切片。

本切片最小自动化测试必须先失败、后通过，并验证 Composition Root 产生语义明确的 `foundationReady` 展示模型。单纯以“工程文件不存在”作为红灯不算测试先行证据。根 View 只接收该注入模型、不构造具体基础设施，由代码评审证明；窗口实际显示该状态，由启动证据证明。无需用 XCTest 内省 SwiftUI 视图树，也无需测试像素或文案布局。

## 5. 实施方式与停止条件

- 遵循最小变更和测试先行原则；先证明工程尚未具备目标行为，再加入满足切片 1 的最少实现；
- 不清理或重写现有架构文档；只有发现可证明的冲突时才提出变更建议；
- 不使用浮动依赖、不增加无关工具、不为了“以后可能需要”建立抽象；
- 遇到签名、SDK、bundle identifier、目录结构或依赖方向歧义时停止并报告；
- 为切片 1 创建独立本地 commit，并保持工作区干净；不配置 remote、不 push；
- 完成切片 1 后停止，不自行继续切片 2–6，等待 Codex 架构评审。

## 6. Cursor 必须回传的证据

Cursor 完成后应给出一份简短的实施报告，至少包含：

1. Gate 0 的 Xcode、Swift、SDK、macOS、架构和 Git 基线结果；
2. 正式 bundle identifier、deployment target、签名方式和项目声明的 entitlement 清单；
3. 新增或修改文件列表，以及每项与本轮目标的对应关系；
4. 自动化测试从目标失败到通过的证据，以及实际执行的 Debug build 与测试命令、退出码和结果摘要；
5. App 启动证据和 `foundationReady` 的可观察结果；
6. target、scheme、Swift Package 依赖列表，以及对构建产物执行签名 entitlement 检查的结果；
7. 文档基线 commit、切片 1 commit、`git status --short --branch` 和 `git diff --check` 结果；
8. 已知限制、未决问题和任何偏离规格之处。

不要只回复“构建通过”或“测试通过”。没有命令、结果和变更范围证据，就不能进入下一切片。

实施报告直接在 Cursor 的回复中返回，本轮不创建 `docs/STAGE-0-EVIDENCE.md`；该证据文档只在阶段 0 全部切片完成时汇总。

## 7. 交回 Codex 后的评审门

Codex 将按以下问题评审，不替 Cursor 修改代码：

- Gate 0 是否真实通过；
- 工程、target、沙盒和标识是否与规格一致；
- Composition Root 是否保持 SwiftUI 与具体基础设施解耦；
- 是否出现阶段外依赖、目录、权限或占位功能；
- 构建、测试和版本控制证据是否足以复现；
- 是否可以授权 Cursor 进入切片 2。

只有评审通过，才生成下一份 Cursor 任务。该评审已经完成，阶段 0 已进入“In implementation”，但在切片 2–6 完成前不能标记为“Completed”。
