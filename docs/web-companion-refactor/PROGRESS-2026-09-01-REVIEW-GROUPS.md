# Review 标签分组与折叠纵切片

日期：2026-09-01
状态：本纵切片已实现并完成合成验收；审查概览达到 `parity-proven`

## 产品与架构判断

Mac `ReviewSuggestionGroupSection` 不是按建议数或标签名临时分类，而是把 Review overview 按本地
标签树投影：组遵循 `sortOrder`，组内标签遵循标签目录顺序，无法匹配的建议归入稳定的“物品与其他”。

Web Host 已有三份可组合的权威投影：`/v1/review/overview` 提供建议统计，`/v1/tags` 提供标签到
`groupID` 的归属，`/v1/tag-groups` 提供组名和 `sortOrder`。本轮复用这些端点，没有新增协议字段，
也没有在浏览器按名字猜分类。折叠集合只保存为非敏感本地界面偏好，不保存第二份标签树。

## 完成的闭环

- Review 标签卡按 Host `sortOrder` 分段，组内保持 Host 标签目录顺序。
- overview 中无法关联标签或标签组的项目稳定进入 `a000…0007`“物品与其他”组；旧投影缺组时使用
  同一稳定 ID 的只读回退标题。
- 组标题展示标签数和待审总数，展开/折叠使用 `aria-expanded` 与 `aria-controls`。
- 折叠状态写入浏览器本地偏好；存储不可用时仍保留当前会话内操作，不让 disclosure 失效。
- 折叠只隐藏卡片网格，不销毁 DOM；刷新后恢复折叠状态。
- 标题支持上/下/左/右方向键和 Home/End 在组间移动，边界按键不触发页面滚动。
- Prism 视觉使用独立的分组容器、计数胶囊和响应式单列布局，没有复制 Mac 原生外观。

## TDD、视觉与边界证据

行为 RED 首先证明旧页面只有平铺卡片，没有三个 Host 分组。实现后同一用例证明乱序组投影按
`sortOrder` 恢复，两个已知标签进入正确组，未知 overview 进入“物品与其他”，标题键盘导航成立，
折叠后重载仍保持隐藏。

- 新分组用例：桌面与 390px 共 2/2 通过，并通过 axe WCAG 2.1 A/AA。
- `format:check`、lint、typecheck、31 个 Vitest 单元/契约测试和生产构建通过。
- 全量 Playwright：110 项中 106 通过、4 项按项目配置跳过、0 失败。
- macOS `build-for-testing`：`TEST BUILD SUCCEEDED`。
- App 内 `WebCompanionV2` 与源码静态资源递归 diff 为空；两侧 `asset-manifest.json` SHA-256 均为
  `0ace69c7600b174287f461d49a38e528da3dd428cb2087b8b4c71ed349e0f7d5`。
- 视觉证据：
  - `evidence/curation/imageall-react-review-groups-chromium-desktop.png`
  - `evidence/curation/imageall-react-review-groups-chromium-mobile.png`

自动化只使用合成标签、来源、任务和媒体，没有读取或遍历 `/Volumes/HDD2`、真实 Photos Library、
真实 iCloud，也没有启动生产 Host。因此证据证明浏览器分组投影、偏好恢复、键盘语义与打包一致，
不证明真实模型建议质量或人工 VoiceOver 听读体验。
