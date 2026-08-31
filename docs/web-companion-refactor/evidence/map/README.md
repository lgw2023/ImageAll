# React 世界地图视觉证据

2026-08-31 使用生产 Vite 构建和 Playwright 捕获。地图聚合、地点照片、位置回填和地方标签请求
均由合成 Host 提供；未读取真实图库、位置、账户或 HDD2 受保护路径。移动端 CSS 视口为
390×844，截图按 3× 设备像素比保存为 1170×2532。

| 文件 | 视口 / 状态 | SHA-256 |
| --- | --- | --- |
| `imageall-react-map-chromium-desktop.png` | 1440×960，选择深圳聚合并显示地点照片 | `e1f3d439c2e72145e8e00901471f9d62334ffd856cbde6b543ce82d9c5f8db61` |
| `imageall-react-map-chromium-mobile.png` | 390×844，移动地图与选中聚合 | `9b129bea23006168fe7b87db5fe02d67a98680c58994e1fdebb0d5c61471b9cb` |

截图中的地图渲染器是与生产 iframe 消息协议一致的合成世界轮廓，用于稳定验证 React 数据层、
跨 frame 选择和响应式布局。生产 App 继续加载同源 `WorldMap` MapLibre/deck.gl 资源；本证据不
证明真实 WebGL 渲染、真实位置精度、位置回填结果或地理编码正确性。`map.spec.ts` 另行覆盖地图
范围进入图库并后退、Host 失败重试、回填开始、地点搜索与确认。
