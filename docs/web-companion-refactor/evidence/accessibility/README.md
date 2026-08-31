# 可访问性与响应式证据

自动化覆盖 1440×960、1024×768、390×844，检查无水平溢出、移动触控尺寸、键盘网格导航、
焦点返回、dialog、命令面板、状态提示以及 WCAG 2.1 A/AA axe 规则。主题专项覆盖 system/light/dark、
reduced-motion、forced-colors、200% 文字与浏览器页面缩放。

截图 `imageall-react-gallery-1024x768.png` 与 gallery/foundation 各自的 desktop/mobile 截图共同形成
三个目标视口的视觉证据。自动化使用语义角色、名称、选中状态和 live region 验证屏幕阅读器所需
接口，但它不是人类使用 VoiceOver 听读后的主观可用性结论；该人工发布检查必须如实单列。

所有验证均使用合成 Host，没有访问 HDD2 受保护数据。
