# Review 来源范围纵切片

日期：2026-09-01

## 目标与取舍

本轮继续以 Mac `LibraryWorkspace` 的审核语义为功能权威，但维持 Nocturne 的独立 Web 外观。来源范围
同时约束审查概览和队列，并允许全部、部分与零来源；零来源不能被 Host 错误折叠为全部来源。

为兼容老客户端，协议新增 `sourceFilterSpecified`：老 payload 的非空 `sourceIDs` 仍推断为精确筛选，
老 payload 的空数组仍保持“全部来源”；新 Web 只有在 URL 明确为零来源时才发送 `sourceIDs=` 并标记
筛选已指定。

## 本轮完成

- 新增 Nocturne 来源范围弹层，列出全部活跃来源，支持一键全选、逐项选择与明确零来源。
- 来源状态可定址：缺省为全部，重复 `source=<uuid>` 为部分，`sourceScope=none` 为零来源。
- 概览、队列、开始审查链接和返回概览链接共享同一范围；刷新与 History 不丢失上下文。
- Query key 按范围隔离；切换时保留旧投影避免页面闪空，同时禁用决定写入并显示切换状态。
- 选择与 dismissed 集合按范围隔离，避免从旧范围携带批量选择。
- Host parser 与 Facade 保留 `nil`（全部）和 `[]`（零来源）的差异；Swift 协议保留老版本解码兼容。
- 来源面板使用真实 button、`aria-expanded`、Escape 和点击外部关闭；桌面为紧凑浮层，移动为满宽布局。
- 修复认证标签前景/背景同时渐变造成的短暂低对比帧，连续 3 次 axe 回归通过。

## TDD 与验证证据

先新增用户行为级 RED：当前页面找不到来源按钮。实现后同一用例验证全部→单来源→零来源、精确 Host
查询、概览/队列计数、URL 与返回导航，并在桌面和移动打开弹层执行 axe WCAG A/AA 扫描。

- Vitest：11 个文件、31 个测试通过。
- 完整 Playwright：98 个配置用例中 94 个通过、4 个按项目配置跳过、0 失败。
- 10k fixture：`routeInteractiveMs=939`、`selectionP95Ms=18.3`、`viewerP95Ms=149.1`、
  `domNodes=713`、`longTaskCount=0`、`anchorDelta=0`。
- Swift protocol：48 个测试通过；Review Host parser/Facade 相关 4 个 Xcode 测试通过。
- `npm run format:check`、`typecheck`、`lint`、`build` 与 `xcodebuild build-for-testing` 通过。
- App bundle 内 WebCompanionV2 与源静态包递归一致；manifest SHA-256 为
  `0f1a0dfe52783d1492aba195027edb5cd72ac145591114378c65459c68111e42`。
- 视觉证据：
  - `evidence/curation/imageall-react-review-source-scope-chromium-desktop.png`
  - `evidence/curation/imageall-react-review-source-scope-chromium-mobile.png`

## 边界与下一步

所有自动化只使用合成 Host/SVG，未读取 `/Volumes/HDD2`、真实 Photos、真实 iCloud 或生产 Host。本轮
不证明真实来源内容、模型建议质量或云端预览解码。

Review 仍是 `in-progress`：下一条优先补齐网格密度/宽高比，再处理 iCloud-only 审核预览；概览侧仍缺
每标签上限、本地模型状态、任务控制与分组折叠，因此不能宣称整个 Mac Review 已完成对齐。
