# React 管理工作区视觉证据

2026-08-31 使用生产 Vite 构建和 Playwright 捕获。全部请求由合成 Host 提供；未读取真实图库、
媒体、账户、磁盘内容或 HDD2 受保护路径。移动端测试的 CSS 视口为 390×844，截图按 3×
设备像素比保存为 1170×2532。

| 文件 | 视口 / 状态 | SHA-256 |
| --- | --- | --- |
| `imageall-react-sources-chromium-desktop.png` | 1440×960，来源刷新完成 | `1c2a23154c48cb5092169e50518e6ac92918ea4f076d8a3f1701c45247e6a36b` |
| `imageall-react-sources-chromium-mobile.png` | 390×844，移动来源管理 | `70717d86efc74d085ef5f7b1f6441c870f8c66e173de40c1699d235d643a8834` |
| `imageall-react-storage-chromium-desktop.png` | 1440×960，缓存清理完成 | `40a9eb7921d93cd1ff0a387b863b633b9b2834b1dbe3fde97c5f84ac5080fa2a` |
| `imageall-react-storage-chromium-mobile.png` | 390×844，移动存储维护 | `12101d54f8ab4f1d5510d39109b5e1579295ad083d9a5e3a41270d3c79bb0c31` |
| `imageall-react-activity-chromium-desktop.png` | 1440×960，Host 暂停后的任务状态 | `c3f65c97a611b9a07aa44413f7a737c51e36091ba52d4cd1bd9de3d5d9cbdc91` |
| `imageall-react-activity-chromium-mobile.png` | 390×844，移动任务控制 | `f6749b06b18aff94e47793d14f76bfa501d74e681abd5199615787080a128e2c` |
| `imageall-react-settings-chromium-desktop.png` | 1440×960，设置保存及旧设备撤销 | `4cf225630f1e659fb34741a2258360f63aee1e81a6c92850f36b6ee7cc2b5604` |
| `imageall-react-settings-chromium-mobile.png` | 390×844，移动设置与当前设备保护 | `08c66df13068059c293e162045b63fd8332cf687cc84a3453966a2f202a66114` |

截图与 `WebCompanionApp/tests/e2e/management.spec.ts` 共同证明合成环境中的来源请求、存储清理
确认、长任务暂停与 Host 回读、设置部分更新、409 冲突提示、当前设备保护及旧设备撤销。它们不
证明真实文件夹/Photos 授权、真实磁盘回收、App 重启、跨网络重连或真实长任务执行。
