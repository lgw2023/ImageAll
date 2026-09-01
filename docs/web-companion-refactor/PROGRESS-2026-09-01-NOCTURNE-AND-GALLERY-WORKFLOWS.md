# Web Companion Nocturne 视觉重构与图库细粒度闭环

日期：2026-09-01
状态：本轮已实现并完成合成验收；“网页功能与 Mac 对齐”的总目标继续实施中

## 产品判断

用户明确要求“功能与 Mac App 对齐”不等于“外观也与 Mac App 对齐”。上一版 Atelier 将印刷感、
米色纸面、衬线标题和常驻三栏工作台混在一起，照片主舞台被侧栏与状态检视器压缩，Web 的优势没有
被发挥出来。

本轮将视觉原则改为 Nocturne：近黑数字暗房、暖白无衬线文字、酸性黄绿动作信号、低 chrome
照片墙和沉浸式查看器。功能、Host 权威性、键盘路径和安全边界保持不变；状态检视器默认收起，
图库获得完整主舞台。

调研依据包括：

- [Linear：A calmer interface for a product in motion](https://linear.app/now/behind-the-latest-design-refresh)：功能持续叠加后，应重新统一层级、动作位置和设计系统；
- [PhotoView：摄影作品可在 minimal/cinematic、editorial/immersive 等不同语言间切换](https://photoview.io/)：内容结构与视觉表达解耦；
- [Lens Editorial Photography 概念](https://www.behance.net/gallery/242360083/Lens-Editorial-Photography-Website-UIUX-Design)：影像优先、强层级、留白和叙事节奏。

只吸收原则，不复制具体页面、商标、字体或品牌资产。

## 完成的功能闭环

### 当前单图即时模型

- 严格解码标准/个人轨道及 results、unavailable、service unavailable、failed 等 Host 状态；
- 只有用户显式点击才发起请求，使用 AbortController 和请求代次拒绝切图后的陈旧结果；
- 个人模型结果可直接“属于/不属于”，只有 Host 标签决定成功后才从当前结果中移除。

### 收藏同步精确重试

- 由当前 Host 权威资产投影计算可见 pending/failed 数量；
- 仅在有问题项时显示持久重试入口，调用 `/v1/favorites/retry` 后重新读取资产和详情；
- 成功、剩余等待和失败分别报告，不把部分成功显示成全部完成。

### 新建标签并原子应用

- 单图查看器与冻结多选都可就地创建标签并立即应用；
- 同名 409 重试保持 operation ID，改名或成功后的下一次提交生成新 ID；
- 成功后保留选区、刷新标签/资产/详情并提供撤销，Escape 只清草稿而不关闭上下文。

### 查看器反馈层修复

原生 modal dialog 会让对话框外的全局 toast 变为 inert。反馈与撤销操作现由同一 `ActionToast`
组件在普通页面或 dialog 顶层中择一渲染，因此单图内的关闭和撤销均可真实交互。

## Nocturne Web 视觉系统

- 新增独立 `src/styles/nocturne.css` 覆盖层，不改变业务组件/Host 协议；
- 默认收起右侧状态检视器，桌面为 224px 导航 + 全宽照片舞台；
- 图库标题、搜索、筛选、卡片、浮动选区和查看器全部改为暗场影像语言；
- 390px 移动端使用图标化顶栏、两列照片墙、折叠筛选和可触控动作；
- 移除会让点击目标移动 240ms 的卡片位移动画，保留不影响稳定点击的边框、光影和图片缩放；
- 登录、模型建议、精简、forced-colors 等旧局部浅色样式一并纳入新 token，未通过降低 axe 标准绕过。

## 验证与证据

- `npm run format:check`、`npm run lint`、`npm run typecheck`：通过；
- `npm run test:run`：11 个文件、31 个测试通过；
- Vite 生产构建与静态清单生成通过；
- Playwright：桌面 1440×960、1024×768、移动 390×844，94 项配置中 90 项执行、4 项按项目配置跳过；
- 10k 合成图库：`routeInteractiveMs=915`、`domNodes=713`、`assetCards=35`、
  `selectionP95Ms=18.0`、`viewerP95Ms=107.7`、`longTaskCount=0`、`anchorDelta=0`；
- Mac `build-for-testing`：`TEST BUILD SUCCEEDED`；
- Host 定向 4 项：静态清单、redacted 单图模型、原子建标签、收藏重试/重放全部通过；
- 源静态目录与构建 App 中 `WebCompanionV2` 递归 diff 为空；
- `asset-manifest.json` SHA-256：`40ec331214b3e457e34b95dd974dcfe5864bb468410baf3eda624ab9b10f9ef4`。

截图证据：

- `evidence/gallery/imageall-react-gallery-chromium-desktop.png`
- `evidence/gallery/imageall-react-gallery-chromium-mobile.png`
- `evidence/gallery/imageall-react-asset-detail-chromium-desktop.png`
- `evidence/gallery/imageall-react-local-model-chromium-{desktop,mobile}.png`
- `evidence/gallery/imageall-react-favorite-retry-chromium-{desktop,mobile}.png`
- `evidence/gallery/imageall-react-inline-tag-chromium-{desktop,mobile}.png`

## 边界与下一步

所有自动化均使用虚构 UUID、合成 SVG 与模拟 Host；没有读取、遍历或写入 `/Volumes/HDD2`、真实
Photos Library 或真实 iCloud，没有启动生产 Host，也没有 push。

本轮不宣称整个 Web/Mac 功能矩阵已经完成。下一轮应继续审计 ReviewRoute 与其它页面的上下文
动作，例如审查队列内的就地新建标签/即时模型入口，并做真实发布环境下的人工视觉与 VoiceOver
检查。视觉是否符合用户审美仍需以用户实际打开后的反馈为准，自动截图只能证明布局、状态和回归。
