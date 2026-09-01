# 单图标签检查器纵切片

日期：2026-09-01
状态：本纵切片已实现并完成合成验收；单图标签检查器达到 `parity-proven`

## 产品与架构判断

Mac 检查器中的标签不是独立的平铺列表：分组由 Host 标签树决定，标签主体承担高频决定，
显式按钮仍作为可发现、可辅助技术读取的完整备选入口。Web 不复制 Mac 外观，而是在 Prism 检查器中
使用紧凑分组容器、状态胶囊和可见的三决定控件。

此轮不增加协议字段。检查器组合 `/v1/assets/:id`、`/v1/tags` 和 `/v1/tag-groups`，只把组折叠集合保存为
非敏感浏览器偏好。Review 概览和单图检查器现在共用同一分组函数和折叠偏好 hook，无法匹配的旧标签
稳定回退到 `a000…0007` “物品与其他”，不按标签名猜测归类。

## 完成的闭环

- 单图标签按 Host `sortOrder` 分组，组内保持 Host 标签目录顺序；未匹配项合并到稳定回退组。
- 组标题显示标签数，通过 `aria-expanded` / `aria-controls` 折叠；重载后恢复状态。
- 组标题支持上/下/左/右方向键和 Home/End 在组间移动焦点。
- 标签主体左键为确认，右键为清除，键盘 X 为拒绝，Delete/Backspace 为清除。
- 确认、拒绝、清除三个显式按钮全部保留；每次 Host 写入并刷新决定后，焦点返回原操作控件。
- 桌面和移动宽度使用同一语义结构，不依赖 hover 才显示关键操作。

## TDD、视觉与边界证据

第一个 RED 证明旧检查器没有 Host 命名分组；第二个 RED 证明没有可聚焦的标签主体；第三个 RED
证明分组只是静态标题。对应 GREEN 分别覆盖分组投影、决定语义/焦点恢复和折叠/键盘导航。

- 新增 2 个场景用例，在桌面和 390px 项目共 4/4 通过，标签区通过 axe WCAG 2.1 A/AA。
- `format:check`、lint、typecheck、31 个 Vitest 单元/契约测试和生产构建通过。
- Playwright 最终全量：114 项中 110 通过、4 项按项目配置跳过、0 失败。首轮并发全量的 10k viewer
  P95 曾单次越过 250ms 门禁到 340.6ms；独立复跑为 92.6ms，最终全量复跑为 91.7ms，其余指标与锚点也通过。
- macOS `build-for-testing` 输出 `TEST BUILD SUCCEEDED`。
- App 包内 `WebCompanionV2` 与源码静态资源递归 diff 为空；两侧 `asset-manifest.json` SHA-256 均为
  `796fcf26cf38ed2a44bb4cc4cc7af8189d3c734c3747f0d91fd51b92611a417d`。
- 视觉证据：
  - `evidence/gallery/imageall-react-inspector-tags-chromium-desktop.png`
  - `evidence/gallery/imageall-react-inspector-tags-chromium-mobile.png`

自动化只使用合成标签、分组、资产和决定响应，没有读取或遍历 `/Volumes/HDD2`、真实 Photos Library、
真实 iCloud，也没有启动生产 Host。因此证据证明浏览器分组投影、决定交互、焦点和折叠语义，
不证明真实大标签库性能或人工 VoiceOver 听读体验。
