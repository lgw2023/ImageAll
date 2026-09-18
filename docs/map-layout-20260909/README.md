# 照片世界原生顶部信息栏遮挡地图控件

2026-09-09，用户指出实际主 App 右上角缩放控件仍被信息栏遮挡，并明确要求使用主工程和当前 App 验证。

网页 `.maplibregl-ctrl-top-right` 使用固定的 `top: 92px`，无法知道原生 heroOverlay 的实际高度；原生与 WebView 安全区也必须一致。先前侧栏修复只处理水平越界，未覆盖顶部遮挡。

本轮选择：主工程 `WorldMapWorkspaceUI.swift` 测量原生信息栏高度，按顶部 22 点边距和下方 12 点间隙计算地图控件位置，通过既有 WKWebView coordinator 更新 DOM style 属性。保留页面的严格 CSP，不添加内联 style 标签或放宽策略。WebView 与原生浮层均遵守容器安全区，窗口变窄导致信息栏换行时重新测量。

按用户本轮要求，直接构建 `/Volumes/SSD1/ImageAll/ImageAll.xcodeproj` 当前工作区，不使用合成 Host。已有审核功能的未提交源码保持原样；本轮只修改 WorldMapWorkspaceUI.swift，并同步相同原生修复到网页工作区。构建输出仍显式隔离，防止在构建过程中破坏正在运行的 App。

主 App 替换前备份：`/Volumes/SSD1/ImageAll/.build/map-header-live-backup/ImageAll.app`，完整签名验证通过。最终运行验证结果见下方记录。

## 实际主 App 验证

- 主工程 Debug 构建成功，完整签名检查通过；应用到用户原运行路径后，全部文件 SHA-256 与构建包一致。
- 已退出并重新打开 `/Volumes/SSD1/Xcode/DerivedData/Build/Products/Debug/ImageAll.app`，在其「照片世界」页面直接检查。
- 实际窗口截图显示：右上角放大、缩小、方向三个按钮全部位于顶部信息栏下方，中间有明确间隙；左下角照片塔导航卡完整可见。
- 点击放大后实际界面 ZOOM 由 1.5 变为 2.5，点击缩小后恢复 1.5。
- 收起侧栏后再次截图，三个按钮仍完整显示且不与信息栏重叠；完成后恢复侧栏。
- 本轮未运行合成测试；未点击位置扫描、补全地点或任何照片修改操作。窄窗口换行分支采用真实高度更新，但未额外缩小窗口进行人工验收。
