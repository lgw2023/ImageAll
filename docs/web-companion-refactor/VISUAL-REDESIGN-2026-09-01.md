# Web Companion 视觉重设计交付（2026-09-01）

## 结果

Web Companion 已从“Mac App 网页复刻 / 通用管理后台”重构为独立的私人影像档案馆。功能、Host 权威、
安全和上下文连续性保持不变；全站视觉、图库浏览和灯箱层级重做。

## 核心变化

- 深墨导航、暖纸工作区、黑色接触印样台构成三层空间；
- 图库使用大字号编辑式标题和紧密 4:3 影像流，工具压缩到必要上下文；
- 灯箱改为近全屏观看区，属性、收藏和标签决定集中在右侧纸色栏；
- 概览、审核、地图、训练、瘦身、来源、存储、标签、活动、设置和认证入口统一到同一视觉系统；
- 390px 保留双列影像流、筛选、分析、框选与全局搜索入口；
- 未引入外部字体、渐变、玻璃模糊或装饰性动画。

完整决策和参考研究见 [ADR-065](../ADR-065-WEB-COMPANION-VISUAL-IDENTITY.md)。

## 视觉证据

| 场景 | 重设计前 | 重设计后 |
| --- | --- | --- |
| 桌面图库 | `evidence/visual-redesign/before/gallery-desktop.png` | `evidence/visual-redesign/after/gallery-desktop.png` |
| 移动图库 | `evidence/visual-redesign/before/gallery-mobile.png` | `evidence/visual-redesign/after/gallery-mobile.png` |
| 桌面灯箱 | `evidence/visual-redesign/before/viewer-desktop.png` | `evidence/visual-redesign/after/viewer-desktop.png` |

## 验证边界

- Playwright 完整矩阵：76 通过、4 跳过；桌面、1024×768、390px、深色、高对比、减少动态和放大
  文字均在矩阵中；
- 10k 性能门槛全部通过；
- 测试只使用虚构 UUID、合成 Host 和合成媒体；未启动生产 Host，未读取或遍历 `/Volumes/HDD2`；
- 当前证据不替代真实设备上的 VoiceOver、真实照片观感和公网移动浏览器手势验收。
