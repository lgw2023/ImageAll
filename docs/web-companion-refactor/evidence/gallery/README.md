# React 图库纵切片视觉证据

2026-08-31 使用生产 Vite 构建和 Playwright 捕获，网络响应来自确定性的合成 Host：120 项合成
资产、合成标签、合成会话和运行时 SVG 预览。过程未读取真实图库、账户、媒体或 HDD2 受保护
路径。

| 文件 | 视口 / 状态 | SHA-256 |
| --- | --- | --- |
| `imageall-react-gallery-chromium-desktop.png` | 1440×960，图库初始态与虚拟网格 | `6740367d49c817fc1f811654417e2df7eaa46599be6c6996761c1efb53165df5` |
| `imageall-react-gallery-chromium-mobile.png` | 390×844，移动图库与双列虚拟网格 | `a690145a4ce6666f68c593242068e35a633db9a3da8851cadde8494ef62b63ec` |
| `imageall-react-asset-detail-chromium-desktop.png` | 1440×960，路由化照片详情 dialog | `cca5e688b1dd015b30c9c62b54b1839af4e40dcd3673a2d4df8015256868f1dd` |

这些截图与 `WebCompanionApp/tests/e2e/gallery.spec.ts` 共同证明当前合成环境下的主路径；它们不
证明真实照片可读性、真实 Photos/Finder 打开、10,000 项性能、视频 Range 或完整
`parity-proven` 验收。
