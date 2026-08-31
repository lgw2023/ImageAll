# React 训练与建议工作台视觉证据

2026-08-31 使用生产 Vite 构建和 Playwright 捕获。训练配置、活动、嵌入准备、样本建议、全库建议和
按标签建议均由合成 Host 提供；未读取真实图库、模型产物、账户或 HDD2 受保护路径。移动端测试的
CSS 视口为 390×844，截图按 3× 设备像素比保存为 1170×2532。

| 文件 | 视口 / 状态 | SHA-256 |
| --- | --- | --- |
| `imageall-react-training-chromium-desktop.png` | 1440×960，相似内容模型已由 Host 接受并显示活动 | `09c8b2e45ce9c01b96c7154ea45b0629b83808a8ca23e9a38d089fa727df6b61` |
| `imageall-react-training-chromium-mobile.png` | 390×844，移动训练配置、活动与停止操作 | `1720265b44d927f104c34d45c861e422bc69bec5c504b8157ebfba9e5388644c` |

截图与 `WebCompanionApp/tests/e2e/training.spec.ts` 共同证明合成环境中的方法/标签/来源表单、非乐观
launch、Host 活动与取消回读、图库选择后的特征准备、个人建议抽检、标准/个人全库建议、按标签
建议、失败重试、移动端无横向溢出和 WCAG 2 A/AA 自动扫描。它们不证明真实训练完成、真实特征
缓存、模型指标/质量、建议正确性、真实图库写入或跨网络长任务恢复。
