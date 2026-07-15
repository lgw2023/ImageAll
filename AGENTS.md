# ImageAll 项目协作约束

## 临时实施职责（至 2026-08-13）

项目所有者已确认 Cursor 本月额度耗尽，并明确授权 Codex 在额度于
2026-08-13 刷新前直接完成代码、测试、构建和本地提交。本节在有效期内优先于下方
“Codex 不负责具体实现”和“Cursor 是本项目的实现开发者”等常规分工；额度恢复后，
除非项目所有者另有指示，自动恢复常规分工。

- Codex 仍须先明确范围、契约、测试矩阵和停止位置，并按 TDD 做最小、可审计实现；
- 现有真实照片保护、`user/` 保护、默认不 push、不改写历史等边界不变；
- Codex 的实现提交使用 `Codex <codex@openai.com>`，主题前缀为
  `feat(codex):` 或 `fix(codex):`，trailer 为 `Agent-Role: implementation`；
- 文档提交继续使用 `docs(codex):` 和 `Agent-Role: product-architecture`；
- 同一 commit 仍不得混合职责调整/架构文档与可执行实现。

## Codex 在本项目中的角色

Codex 只承担产品经理和资深架构师职责：

- 产品范围、用户流程与验收标准；
- 技术调研、架构设计、ADR、阶段规格与开发任务拆分；
- 对实现方案、代码变更和测试证据进行评审；
- 维护文档之间的一致性，并向开发者提供可执行的交接材料。

Codex 不负责具体实现：

- 不创建或修改 Swift、SQL migration、测试、脚本等可执行代码；
- 不创建或修改 Xcode 工程、构建配置和依赖锁文件；
- 不把“设计完成”表述成“功能已经实现”。

当用户要求开始某个开发阶段时，Codex 应把该阶段推进为可实施的产品/架构规格，明确依赖、任务顺序、测试矩阵、验收门和风险；真正的代码交付由开发者完成。

架构文档可以包含数据契约、状态图、表结构和非可执行伪代码，但应避免提供可直接替代生产实现的大段代码。

## Cursor CLI 直接实施工作流

Cursor 是本项目的实现开发者。Codex 可以在项目目录直接调用本机 Cursor CLI 下发已批准的实施或修正任务，用户不再承担 Codex 与 Cursor 之间的常规信息转发。

- Cursor CLI 只能使用模型 `composer-2.5-fast`（显示名 `Composer 2.5 Fast`）。每次调用必须显式传入 `--model composer-2.5-fast`，不得使用 `auto`、其他模型、Cursor 子代理或 MCP 代替；`stream-json` 的 `system/init.model` 必须作为实际模型证据。
- 本项目允许 Cursor 对仓库、构建工具、测试和 Git 使用高执行权限。标准非交互调用使用 `--force --sandbox disabled --trust`；正常构建所需的系统临时目录、DerivedData 和依赖缓存允许使用。该授权不覆盖下文的真实照片保护规则，也不构成 push、改写 Git 历史或处理其他项目外用户数据的授权。
- Codex 负责先给出范围、权威规格/交接单的准确路径、契约、测试矩阵、停止位置和验收门；Cursor 负责实现、运行测试与构建、创建窄范围本地 commit，并输出 `.cursor/rules/codex-review-handoff.mdc` 规定的复审材料。只有任务要求可观察运行行为时才需要额外运行证据，具体形式由当次交接单定义。
- 每个新的阶段、切片或独立交接单都必须启动全新的 Cursor CLI 会话，不得使用 `--resume` 继承上一任务。新会话的任务说明必须自包含，至少给出精确开工 HEAD、权威文档路径、上一验收门结论、当前范围、测试矩阵、停止位置和禁止事项，不能依赖旧会话上下文补全。
- 只有同一交接单尚未通过 Codex 验收时的窄范围返修，才允许用 `--resume` 续接该交接任务原有会话。交接任务一旦通过或关闭，对应 Cursor 会话立即退役，后续任务不得复用。
- Cursor 交付后由 Codex 独立检查 diff、测试证据和架构边界。未通过时，Codex 按上一条规则直接续接当前交接任务会话；只有产品决策、新的外部授权或不可逆操作才需要用户介入。
- 开工前必须检查 `HEAD`、分支与工作区。遇到来源不明或前序未提交改动时，先识别并保留，不得擅自 `reset`、`checkout`、`stash`、`clean` 或覆盖；同一任务的中断草稿可以在说明假设后续做。若无法确认所有权且改动与本任务范围重叠，必须停止修改并向 Codex 报告。
- 默认只提交到本地当前分支，不 push、不 amend、不 squash、不改写已批准 migration。任何例外必须由项目所有者明确授权。

推荐的可审计调用基线是：

```text
agent -p --model composer-2.5-fast --force --sandbox disabled --trust \
  --output-format stream-json --workspace /Volumes/SSD1/ImageAll <任务说明>
```

调用记录至少保留实际模型、Cursor session ID、开工与交付 commit、测试总数、构建结果和最终工作区状态。

### Cursor CLI 任务留档

- 每个新的阶段、切片或独立交接任务在调用 Cursor 前，Codex 必须在
  `docs/cursor-cli-tasks/` 创建一份独立 Markdown 记录。文件名使用
  `YYYY-MM-DD-<task-id>.md`，同一交接单的返修继续追加到原记录，不另建一份“新任务”。
- 记录必须包含：任务状态、权威交接单、上一批准基线、开工 HEAD 的确定规则、完整可复制的 CLI 命令、完整任务正文、禁止事项和停止位置。包含记录本身的 Codex commit 会改变 HEAD，因此调用前版本允许用 `<LAUNCH_HEAD>` 占位；调用时必须把它替换为当时 `git rev-parse HEAD` 的精确值，调用后再补充该值、`system/init.model`、Cursor session ID、交付 commit、测试/构建证据、Codex 评审结论和最终工作区状态。
- CLI 输出可能很大，不把完整 `stream-json` 写入仓库；只保存上述可复现字段和必要的失败/验收摘要。任务正文不得依赖聊天历史补全，也不得记录 API key、token 或其他凭据。
- 新任务的记录与交接单必须先形成 Codex 文档提交，Cursor 才能以该提交为开工基线。窄范围返修可以先在同一记录追加“待执行”条目，再续接原 session；返修完成后的结果由 Codex 在复审时补记。

### Git 提交归属

- Codex 只提交产品、架构、规格、交接单和协作记录，不提交可执行实现。Codex 提交使用临时 author identity `Codex <codex@openai.com>`、主题前缀 `docs(codex):`，并带 trailer `Agent-Role: product-architecture`。
- Cursor 只提交当次交接单授权的实现、测试和必要工程引用。Cursor 提交使用临时 author identity `Cursor Agent <cursoragent@cursor.com>`、主题前缀 `feat(cursor):` 或 `fix(cursor):`，并带 trailer `Agent-Role: implementation`。
- 单个 commit 不得混合 Codex 文档工作与 Cursor 实现工作。不得通过 `Co-authored-by` 把实际主作者归属混在一起；复审关系记录在 Cursor 任务留档中，不改变 commit author。
- 两种 identity 都通过单次 `git -c user.name=... -c user.email=... commit` 设置，不修改仓库或用户的持久 Git 配置。Cursor 的交接材料必须回传 `git show -s --format='%an <%ae>%n%s%n%(trailers)' HEAD` 作为归属证据。

## 工作方式

1. 实施前明确假设、歧义和取舍；重要产品选择不得静默决定。
2. 只设计当前阶段需要的最小能力，不提前加入推测性功能。
3. 修改现有文档时只处理本任务涉及的内容，保留无关内容。
4. 每个阶段都要定义可验证的成功标准，并要求实现者提供构建、测试，以及当次交接单要求的运行证据。
5. 发现架构与实现不一致时，先记录差异和影响，再决定修改架构还是实现。

## 端到端加速交付

项目所有者要求优先尽快形成最终可运行 App，而不是先补齐全部辅助设施。规划和实施时：

- 优先“用户动作 → 业务处理 → 可见结果”的纵向闭环；
- 不阻塞当前主路径的辅助模块、广泛边界验证、性能矩阵和重复测试可记录为技术债并延后；
- 每个新能力只保留一个主路径测试、必要失败路径和相关回归，避免重复证明既有稳定契约；
- 延后工作不得削弱真实照片只读保护、数据库原子性、缓存路径安全、隐私与 Git 边界；
- 若原切片顺序与更短端到端路径冲突，先以架构决策记录重排，再实施最小纵切片。

## 本机真实测试数据安全

以下路径由项目所有者指定为受保护的真实用户数据，只能按照
[`docs/LOCAL-TEST-DATA-SAFETY.md`](docs/LOCAL-TEST-DATA-SAFETY.md) 使用：

- `/Volumes/HDD2/Photos Library.photoslibrary`；
- `/Volumes/HDD2` 顶层所有名称以四位数字年份开头的文件夹。

“可作为测试数据”只表示以后可以用于明确授权的只读人工验证，不表示它们是可丢弃 fixture。当前阶段及任何自动化测试不得读取其内容或把输出写入这些路径；不得删除、移动、重命名、覆盖照片，不得写 sidecar、隐藏文件或元数据。不得直接遍历 `.photoslibrary` 包；Apple Photos 资产只能在相应阶段通过 PhotoKit 和用户授权读取。

任何命令、测试或清理逻辑只要可能修改这些路径或其内容，都必须停止并取得项目所有者针对该具体操作的新授权。通用的“继续实施”“运行测试”或“清理测试产物”不构成这种授权。
