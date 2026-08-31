# React 概览、审查与标签库视觉证据

2026-08-31 使用生产 Vite 构建和 Playwright 捕获。全部请求由合成 Host 提供：120 项合成媒体、
8 项审查建议、2 个初始标签以及测试中创建的合成分组。未读取真实图库、媒体、账户或 HDD2
受保护路径。

| 文件 | 视口 / 状态 | SHA-256 |
| --- | --- | --- |
| `imageall-react-overview-chromium-desktop.png` | 1440×960，Host 图库统计 | `c7ba5e8730d0b40b7d203917441bd7cd05be1162cf23a6ddefb3473338a13264` |
| `imageall-react-overview-chromium-mobile.png` | 390×844，移动概览 | `12b9ebd2da0a285b7df0561238d59428634ef03076f14a448d77b6934896c729` |
| `imageall-react-review-chromium-desktop.png` | 1440×960，8 项审查队列 | `eadfe9cae1f05e9f6db3d2021f20592de9c9ebd7c24dd355591e9584b6a573fd` |
| `imageall-react-review-chromium-mobile.png` | 390×844，移动审查队列 | `343e235956843b884b4ae5af6e20c3d5bc10cc302703fd082ee66ece3ee23a3a` |
| `imageall-react-tags-chromium-desktop.png` | 1440×960，标签改名与分组移动结果 | `be08dbbfde43ae1d9037709bb04c76a4a18d4f62ad770773fa732f80e03164c1` |
| `imageall-react-tags-chromium-mobile.png` | 390×844，移动标签管理 | `fbf053fb1def2c52d36eb86f28862d62824f01e73f706f97f4c272ff4d002e03` |

截图与 `WebCompanionApp/tests/e2e/curation.spec.ts` 共同证明合成环境中的统计导航、审查单项/
批量决定、键盘决定、撤销、标签分组创建、改名和移动。它们不证明真实模型建议质量、真实大队列
性能、VoiceOver 人工验收或所有 Host 冲突分支。
