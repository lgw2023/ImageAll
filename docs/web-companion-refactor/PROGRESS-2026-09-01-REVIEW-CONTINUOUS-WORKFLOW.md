# Review 连续单图审核纵切片

日期：2026-09-01

## 为什么继续改

上一轮完成 Nocturne 独立 Web 视觉后，本轮重新以当前 Mac 源码为功能权威审计审核工作区。
`PersonalizationReviewUI.swift` 和 `LibraryWorkspace.swift` 证明 Mac 的日常审核主路径不是一组卡片按钮，
而是：网格选中、Space 进入单图、P/X/U 连续判断、方向键移动、判断后自动落到下一条，并在返回
网格时保留当前位置。

审计也纠正了旧矩阵的过度结论：Web 审查概览尚未覆盖来源范围、每标签上限、本地模型状态和任务
控制；审核队列也仍缺来源筛选、网格密度/宽高比与 iCloud-only 单图恢复。因此两行均恢复为
`in-progress`，不能仅凭基础卡片和决定 API 宣称全量对齐。

## 本轮完成

- 新增沉浸式 `ReviewSinglePhotoDialog`，视觉继续使用 Nocturne，不复制 Mac 外观。
- 审核网格自动建立当前项；Space/Enter 进入单图，双击卡片也可进入。
- 单图支持左右方向键和可见上一条/下一条控制。
- 快捷键与 Mac 对齐为 P“属于”、X“不属于”、U“稍后”；A/R/S 继续作为兼容别名。
- P/X 成功后保留单图模式并自动进入下一条；最后一条会安全回绕到仍待审项目或退出空队列。
- U 只移动审核焦点，不再把建议从当前会话错误隐藏；卡片“稍后处理”也采用同一语义。
- Esc、背景点击、关闭按钮和再次按 Space 都可返回网格；当前项以 `aria-current` 与高亮边框保留。
- 决定和“稍后”反馈显示在 modal top layer 内，避免底层 toast 被原生 `<dialog>` 惰性层屏蔽。
- 支持 Meta/Ctrl+A 选择全部已载入建议，同时保留既有单项、批量、撤销和旧快捷键回归。

## TDD 与验证证据

先新增用户行为级 RED：Space 后应出现“单图审核”，U 应前进但第一条仍在队列，P 必须向 Host
提交第二条的精确 asset ID 并自动显示第三条，Esc 后第三条仍是当前项。旧产物按预期找不到对话框；
生产构建后测试进入 GREEN。

- Vitest：11 个文件、31 个测试通过。
- Curation Playwright：桌面与移动共 10 个测试通过，包括新连续审核流程和 axe WCAG A/AA。
- 完整 Playwright：96 个配置用例中 92 个通过、4 个按项目配置跳过、0 失败；10k fixture
  `routeInteractiveMs=871`、`selectionP95Ms=17.4`、`viewerP95Ms=118.7`、`longTaskCount=0`、
  `anchorDelta=0`。
- 视觉证据：
  - `evidence/curation/imageall-react-review-single-photo-chromium-desktop.png`
  - `evidence/curation/imageall-react-review-single-photo-chromium-mobile.png`
- `npm run lint`、`npm run typecheck`、`npm run build` 通过。
- `xcodebuild build-for-testing` 通过；Swift
  `testWebV2AssetStoreUsesAuditedManifestHashesAndSPARouteAllowlist` 通过。
- 源静态包与 `ImageAll.app/Contents/Resources/WebCompanionV2` 递归一致；manifest SHA-256 为
  `db3d1842055ad14a297fc09940abaa735e375f355a37fb19f3c458c99257729c`。

## 边界与下一步

所有自动化只使用合成 Host/SVG，未访问 `/Volumes/HDD2`、真实 Photos、真实 iCloud 或生产 Host。
本轮不证明模型建议质量、真实预览解码或超大审核队列性能。

下一条纵切片应优先复用 Host 已有 `sourceIDs` 参数，把来源范围同时接到审查概览与队列，并保持
切换范围时的当前项、滚动位置和请求竞态安全；随后再接每标签上限、本地模型状态与任务控制。
