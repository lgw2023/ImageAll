# Web Companion Prism 视觉重构进展（2026-09-01）

## 目标澄清

项目所有者明确要求：Web 与 Mac App 对齐的是功能、状态语义与安全边界，不是外观。此前的桌面面板复刻
以及后续“私人档案馆”方案都过于像管理后台。本轮将 Web 重构为独立、现代、内容优先的创意影像工作台。

## 行业参考与提炼

- [Immich](https://immich.app/)：照片内容优先，管理能力围绕媒体展开；
- [Eagle](https://en.eagle.cool/)：大规模素材的快速浏览、多维筛选、悬停与键盘预览；
- [Air](https://air.inc/)：高质量缩略图、轻量导航与创意任务上下文；
- [Cosmos](https://play.google.com/store/apps/details?id=so.cosmos.www)：视觉发现和收藏优先；
- [Linear](https://linear.app/)：低噪声导航、精确层级和即时状态反馈。

只提取交互规律，不复制任何产品的品牌、组件或页面。

## 已完成

1. 新增 ImageAll Prism 视觉层：深色沉浸画布、紫罗兰/冷青环境光、系统无衬线字体和柔和玻璃层级；
2. 全局导航、顶栏、工作区与可选检视器重排为浮动框架，内容区成为视觉主角；
3. 图库改为大缩略图、弱边框、下缘元数据和悬停抬升，搜索、筛选、分析、框选能力保持原契约；
4. 审查概览把本地模型从狭窄左栏重构成横向 AI 工作台，标准/个人双轨并列，Host 权威状态、进度和动作
   完整保留；
5. 审查标签改为内容入口卡片；390 px 下模型工作台与标签卡片自动折叠为单列，图库保持双列；
6. 修订 ADR-065，明确“功能对齐不等于外观对齐”，允许受控渐变、玻璃模糊与柔和光效；
7. 全程只使用合成 Host 与合成媒体，没有读取、遍历或写入真实 Photos/iCloud/HDD2 数据。

## 视觉证据

- `evidence/gallery/imageall-react-gallery-chromium-desktop.png`
- `evidence/gallery/imageall-react-gallery-chromium-mobile.png`
- `evidence/curation/imageall-react-review-models-chromium-desktop.png`
- `evidence/curation/imageall-react-review-models-chromium-mobile.png`

## 不变边界

- Mac Host 仍是所有列表、任务、修改和设置的唯一权威；
- 本轮没有改 API、路由、URL 筛选、快捷键、撤销、分页或任务状态机；
- 10k 图库虚拟化、PWA 私有数据边界和受保护真实图库边界不变。

## 验证

- `format:check`、lint、typecheck：通过；
- Vitest：11 个文件、31 项全部通过；
- Playwright：108 项中 104 项通过、4 项按浏览器项目配置跳过、0 失败；桌面与 390 px 主路径通过
  axe WCAG 2.1 A/AA；
- 10k 合成图库：首卡可交互 993 ms，DOM 713，卡片 35，选择反馈 p95 16.9 ms，灯箱 p95
  118.3 ms，长任务 0，滚动锚点偏差 0 px；
- `xcodebuild ... build-for-testing`：`TEST BUILD SUCCEEDED`；构建后 App 内 `WebCompanionV2` 与源资源
  `diff -qr` 无差异；
- `asset-manifest.json` SHA-256：`369765f5a446f32d9bb9d2b79d14e75cb107edcf3f5e610af9e4046f22460446`。
