# Review 本地模型控制纵切片

日期：2026-09-01
状态：本纵切片已实现并完成合成验收；审查概览仍为 `in-progress`

## 产品与架构判断

Mac `ReviewLocalModelPanel` 在审核概览直接展示服务健康、标准模型、个人模型和活动任务动作。新版
React 此前只能去 Training 页面管理相同 Host 能力，Review 本身没有状态或入口，打断了审核工作流。

Host 已有完整 `librarySuggestions` capability、`GET /v1/library-suggestions` 状态投影、POST 启动命令
和通用 job action；本轮不新增协议。实现使用自包含 `ReviewLocalModelPanel` 深模块，公开接口只接收
当前 Review 来源范围，内部负责轮询、双轨互斥、失效刷新、错误调和和 Query 缓存共享。视觉采用
Prism 横向 AI 工作台，不复制 Mac 原生面板。

## 完成的闭环

- 仅当 Host 声明 `librarySuggestions` 时显示本地模型控制台；旧 Host 不出现失效入口。
- 服务卡显示 ready/degraded/unavailable、提供方、模型 ID 和版本；“检查服务”显式请求 Host 刷新。
- 标准/个人模型卡展示模式、权威状态、已检/总数、建议数、跳过数和进度。
- 启动命令冻结并提交当前 Review 来源范围；空来源禁用启动，不把空数组误解释为全库。
- 标准与个人任务互斥；运行、暂停与可重试状态期间不能并发启动另一轨。
- 暂停、继续、取消完全使用 Host `availableActions`；完成或取消后重新开放生成入口。
- 所有命令成功后刷新模型、Review 概览和通用 jobs 投影；活动任务每两秒回读，不伪造进度。
- 503 原位使用 `role=alert`，保留来源范围和重试入口；成功反馈与错误语义分离。

## TDD、视觉与边界证据

第一条 RED 证明旧页面不存在“本地模型”区域；实现后覆盖服务刷新、标准轨精确来源启动、24/120
进度、个人轨并发禁用、暂停→继续→取消、取消后个人轨启动。第二条 RED 锁定启动 503 必须是告警
而不是普通状态；实现后证明原值/来源不丢并可直接重试成功。

- Review/curation 聚焦回归：22 个桌面与移动用例通过。
- 桌面与 390px 主链均通过 axe WCAG 2.1 A/AA。
- `format:check`、lint、typecheck、31 个 Vitest 单元/契约测试与生产构建通过。
- 全量 Playwright：108 项中 104 通过、4 项按项目配置跳过、0 失败。
- macOS `build-for-testing` 通过；App 内 `WebCompanionV2` 与源资源 `diff -qr` 无差异；
  `asset-manifest.json` SHA-256 为
  `369765f5a446f32d9bb9d2b79d14e75cb107edcf3f5e610af9e4046f22460446`。
- 视觉证据：
  - `evidence/curation/imageall-react-review-models-chromium-desktop.png`
  - `evidence/curation/imageall-react-review-models-chromium-mobile.png`

自动化只使用合成服务、任务、来源和标签；没有读取或遍历 `/Volumes/HDD2`、真实 Photos Library、
真实 iCloud，也没有启动生产 Host。因此证据证明 Web 控制、状态调和与布局，不证明真实模型推理、
吞吐、准确率或建议质量。

## 剩余边界

审查概览的来源、上限、模型任务和队列入口已形成纵向闭环；剩余已知结构性缺口是按标签组折叠与
键盘组导航。当前 overview DTO 没有标签组映射，必须先扩展 Host 权威投影再实现，不能根据标签名
或前端顺序猜分组。

后续核对修正：overview DTO 本身虽不携带 `groupID`，但既有 `/v1/tags` 与 `/v1/tag-groups` 已分别
提供标签归属和组顺序，因此无需扩协议。该缺口已由 `PROGRESS-2026-09-01-REVIEW-GROUPS.md` 封闭。
