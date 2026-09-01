# Web Companion Helios 全站重设计进展（2026-09-01）

## 目标纠正

本轮按项目所有者的明确反馈重新定义目标：Web 与 Mac App 对齐的是功能完整性、操作语义、Host 权威
和安全边界；视觉上不复刻 Mac。旧的桌面面板式和深色管理后台式方向均停止扩展，Web 改为独立的
图片优先产品。

## 研究与设计结论

- [Immich](https://immich.app/) 与 [Ente Photos](https://ente.com/)证明图库、搜索、地图与安全能力可以
  围绕照片而非设置面板组织；
- [Adobe Lightroom Web](https://lightroom.adobe.com/)强调摄影内容是第一视觉层；
- [mymind](https://mymind.com/)、[Cosmos](https://www.cosmos.so/)和 [Are.na](https://www.are.na/)
  提供了更轻的视觉画布、编辑化留白和弱化常驻控件的参考；
- [Awwwards Interaction Design](https://www.awwwards.com/websites/interaction-design/)用于校准空间层级和
  交互反馈的表现力。

最终没有复制任何参考页面，而是把这些原则组合为 ImageAll Helios：暖白画布、72 px 浮动图标轨、
浮动标题栏、大幅圆角影像卡片，以及紫罗兰、珊瑚、青色、青柠四组克制的状态强调。

## 已完成

1. 新增 `helios.css` 作为最终全局视觉组合层，覆盖认证、图库、概览、审查、地图、训练、瘦身、来源、
   存储、标签、活动和设置；
2. 关闭的检视器不再占位，桌面媒体工作区超过视口宽度 90%，导航收敛到 72 px；
3. 图库高级筛选默认折叠；移动端筛选改为固定、可滚动、可显式关闭的玻璃抽屉；
4. 合成 Host 缩略图改为确定性的彩色抽象 SVG，使视觉回归能验证照片墙节奏而不接触真实照片；
5. `ThemeProvider` 同步更新浏览器 `theme-color`，PWA 安装背景切换为 Helios 暖白；深色、减少动态、
   强制颜色和放大文字仍保留；
6. 存储工作台同时补齐清理、导出、迁移与重启四类 Host 动作，包含状态门控、冲突锁、应用内确认、
   稳定操作 ID 重试和完整结果投影；
7. Review、Training、Source 的状态文字和移动端交互重新校准对比度与遮挡行为。

## TDD 与回归证据

- 先加入桌面视觉结构断言，RED 证据为缺少 `data-visual-system`；实现后验证 72 px 导航、标题栏位置、
  工作区占比、影像圆角和无水平溢出；
- PWA 测试先因旧主题色 `#11110f` 失败，再改为 `#f3f2ed` 并通过；
- `format:check`、lint、typecheck：通过；
- Vitest：11 个文件、31 项全部通过；
- Playwright：158 项中 152 项通过、6 项按项目配置跳过、0 失败；桌面与 390 px 移动主路径通过；
- 10k 合成图库：fixture SHA-256 `0db043e9e228ff18deaa183a280c69b6ed05257bdbc1c388608e27042f8c34cc`，
  首卡可交互 919 ms，DOM 781，卡片 36，选择 p95 17.5 ms，灯箱 p95 82.2 ms，长任务 0，
  锚点偏差 0 px。
- macOS `xcodebuild ... build-for-testing`：`TEST BUILD SUCCEEDED`；构建产物内 `WebCompanionV2` 与源资源
  `diff -qr` 无差异；
- `asset-manifest.json` SHA-256：`9595d13261aae0e70f036ab6c6374fd56c72aabc917b102d8537c07f90ce9176`。

## 视觉证据

- `evidence/gallery/imageall-react-gallery-chromium-desktop.png`
- `evidence/gallery/imageall-react-gallery-chromium-mobile.png`
- `evidence/curation/imageall-react-overview-chromium-{desktop,mobile}.png`
- `evidence/curation/imageall-react-review-chromium-desktop.png`
- `evidence/management/imageall-react-storage-vault-chromium-{desktop,mobile}.png`
- `evidence/management/imageall-react-sources-chromium-desktop.png`
- `evidence/map/imageall-react-map-chromium-desktop.png`
- `evidence/training/imageall-react-training-chromium-desktop.png`

## 证据边界

- 自动化只使用合成 Host 与合成媒体，未读取、遍历或写入 HDD2、Photos Library 或 iCloud；
- 存储动作验证的是请求、确认、冲突、失败与结果投影，不证明真实磁盘回收、真实导出、迁移或 App 重启；
- 自动化可访问性不能代替人工 VoiceOver、真实浏览器渲染审美评审或真实大图库人工验收。
