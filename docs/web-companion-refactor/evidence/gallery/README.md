# React 图库纵切片视觉证据

2026-08-31 使用生产 Vite 构建和 Playwright 捕获，网络响应来自确定性的合成 Host：120 项合成
资产、合成标签、合成会话和运行时 SVG 预览。过程未读取真实图库、账户、媒体或 HDD2 受保护
路径。

| 文件 | 视口 / 状态 | SHA-256 |
| --- | --- | --- |
| `imageall-react-gallery-chromium-desktop.png` | 1440×960，图库初始态与虚拟网格 | `ee9e729f48c0f809b10cd3ca7a7bc66cf60693516216f0e4779414dbd5389254` |
| `imageall-react-gallery-chromium-mobile.png` | 390×844，移动图库与双列虚拟网格 | `868f8bc63979f03ff6cf9664263f7f8142ed79bafb1d644d08f8733631276513` |
| `imageall-react-asset-detail-chromium-desktop.png` | 1440×960，路由化照片详情 dialog | `62a67de6d839e69175b6187523a878b49fd3108216879b81670ba83a150272d3` |

这些截图与 `WebCompanionApp/tests/e2e/gallery.spec.ts` 共同证明当前合成环境下的主路径；它们不
证明真实照片可读性、真实 Photos/Finder 打开、10,000 项性能、视频 Range 或完整
`parity-proven` 验收。
