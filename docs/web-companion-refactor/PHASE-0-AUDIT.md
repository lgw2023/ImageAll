# 阶段 0：Web Companion 现状审计

## 结论

当前 Web Companion 业务能力已相当完整，且 Host 端的鉴权、Origin 校验、CSP、Cookie、媒体
Range 和事件通道有较强测试保护。问题集中在前端形态：三个巨型手写资源、一个全局状态容器、
大量隐式 DOM 契约、混合图标语言，以及无标准构建/类型/lint/单测/视觉回归基础。因此应保留 Swift Host
的权威边界，通过并行入口替换 Web UI，而不是连 API 和数据层一起重写。

## 实现与资源链

```text
Mac App / LibraryWorkspace
        │ commands + query ports
        ▼
RemoteHTTPServer  ──── auth / Origin / CSP / Cookie / Range / WebSocket
        │                         │
        │ /v1/* JSON + media     └─ RemoteWebCompanionAssetStore
        ▼                                      │ fixed route table
ImageAllRemoteProtocol DTOs                        ▼
                                           Resources/WebCompanion
                                           index.html + app.css + app.js
```

- Xcode 将 `ImageAll/Resources/WebCompanion` 作为整个 folder resource 复制到 App bundle。
- `RemoteWebCompanionAssetStore` 使用固定路径、文件名和 MIME 表读取资源；无法直接服务 Vite 哈希文件
  或安全的 SPA fallback。
- 静态文件在 API 鉴权前可读，但其安全响应头依然严格；私有 API 和媒体继续由会话校验。
- 当前静态响应使用 `Cache-Control: no-store` 和 `Pragma: no-cache`。

## 规模和耦合

| 项目 | 基线 |
| --- | ---: |
| `index.html` | 3,366 行，196 KiB |
| `app.css` | 16,267 行，328 KiB |
| `app.js` | 50,176 行，1.9 MiB |
| `service-worker.js` | 96 行 |
| 顶层 JavaScript 函数 | 1,754 |
| DOM 元素参照 | 约 935 |
| 旧浏览器 Playwright 脚本 | 18 份，39,629 行，约 4,286 个断言 |
| `RemoteHTTPServerTests.swift` | 约 7,200 行 |
| Remote Protocol Swift 源码 | 21 份，5,137 行 |

`app.js` 通过一个巨型全局 `state` 对象联系资源、筛选、选择、批处理、审查、训练、精简、
地图、设置、会话和各类 overlay。History API 可表达 Gallery、Review、Training、Slimming、World Map
和 Gallery Overview 六类顶层空间，但路由、overlay 和工作区状态仍主要由命令式 DOM 逻辑实现。

## 页面与工作流盘点

| 领域 | 旧 Web 现状 | 主要风险 |
| --- | --- | --- |
| 连接/会话 | 配对、账户登录、refresh、logout、重连 | 与全局状态和顶栏强耦合 |
| 图库 | 分页加载、筛选、排序、视图、选择、收藏 | 无虚拟化，长会话 DOM 持续增长 |
| 图片查看 | 受保护 blob、相邻预取、取消、全屏 | object URL 生命周期分散 |
| 标签/批处理 | 决策、创建应用、选择标签、undo | 预览、提交、撤销状态难以局部推理 |
| 审查 | 总览、队列、批量决策、undo | 队列过渡与键盘契约隐式 |
| 训练 | setup、launch、activity、嵌入/样本/标签建议 | 高密度表单和任务状态集中在单文件 |
| 精简 | 工作区、setup、阈值、cluster review、cleanup/recycle | 高风险写操作需更清晰预览/确认边界 |
| 世界地图 | snapshot、selection、backfill、place tags | 存在独立地图资源和局部变量体系 |
| 来源/存储/设置 | 列表、操作请求、通知、通用设置 | 反馈和审计证据穿插在多个 overlay |

详细对照见 [FEATURE-PARITY-MATRIX.md](FEATURE-PARITY-MATRIX.md)。

## 数据、图像与缓存行为

- API helper 使用同源 credentials，Basic 凭据只在内存，401 时最多执行一次 refresh 重试。
- 延迟图像通过受保护 fetch 转 object URL，使用 `AbortController` 取消；Lightbox 只预取相邻两张。
- Gallery 增量调和卡片，但已加载的卡片全部留在 DOM；默认页大小 72，历史上限 5,000。
- localStorage 只保存布局、排序等非敏感偏好；新应用不得扩大到 token、资产详情或业务结果。
- 现有 Service Worker 只服务认证协调，ADR-048 明确不提供 offline shell。ADR-063 仅对新版增加
  可版本化的公共外壳缓存，不缓存任何私有数据。

## 安全边界

1. CSP 默认只允许同源，禁止内联 script/style，`frame-ancestors 'none'`。
2. 会话 Cookie 是 `Secure; HttpOnly; SameSite=Strict`；配对秘密放在 URL fragment，不进入 Host 请求日志。
3. Cookie/Basic 状态下的变更请求校验 Origin/Host 和 `Sec-Fetch-Site`。
4. WebSocket 独立鉴权；媒体 GET/HEAD 保留 Range 语义。
5. 新静态资源清单必须阻止 `..`、反斜杠、重复解码、未知 MIME 和清单外文件；SPA fallback
   只对无扩展名的已知前端路由生效，不得吞掉 `/v1/*` 404。

## 测试能力与技术债

### 现有保护

- Swift 集成测试覆盖会话、静态资源、CSP、Origin、Cookie、WebSocket、媒体 Range 和主要 API。
- 18 份 Python Playwright 脚本覆盖桌面/移动、焦点/历史、对话框、图库、审查、训练、精简、
  地图和设置。
- 合成 HTTP fixture 下的旧版筛选/审查/Lightbox 全流程已通过。

### 债务

- 没有 package manifest、lockfile、TypeScript strict、lint、格式化、组件单测或标准 Playwright config。
- 旧脚本硬编码 Google Chrome 路径，截图写入 `/tmp`，没有可版本化的差异基线和阈值。
- Swift 测试中有大段对 `app.js` 函数名的字符串检查，适合旧实现守护，不适合作为新架构契约。
- 没有 axe/WCAG 自动门，没有 VoiceOver 验收记录。部分默认控件高约 30 px，触控选择按钮
  约 42 px，低于本重构的 44 px 触控目标。
- 图标体系混用 Unicode/emoji/文字，统计到 178 处类图标用法。

## 10,000 条合成基线

向旧版注入 10,000 条不含真实媒体的合成摘要，在一次受限本地浏览器运行中得到：

| 指标 | 值 |
| --- | ---: |
| 首次调和 10,000 张卡片 | 4,742.3 ms |
| 一次选择反应 | 49.5 ms |
| 卡片数 | 10,000 |
| DOM 节点数 | 72,410 |
| 滚动高度 | 250,094 px |

这是发现性基线，不是正式性能验收；机型、浏览器版本和 heap 采样未形成严格实验契约。
但 72,410 个 DOM 节点足以证明新版需要虚拟化，不应只优化 CSS。

## 视觉基线

| 视口 | 证据 | SHA-256 |
| --- | --- | --- |
| 1440×960 | [桌面](evidence/phase-0/imageall-baseline-gallery-1440x960.png) | `82cafd8ae2b7a57e6f27fc3fa24cc3a6c3dc275035c062a0b0914040e36408a6` |
| 1024×768 | [紧凑桌面](evidence/phase-0/imageall-baseline-gallery-1024x768.png) | `f4055deda54a90982763fe12e6540ccf1b4545b2baab56a2ce87ab2f566394b5` |
| 390×844 | [移动](evidence/phase-0/imageall-baseline-gallery-390x844.png) | `176c883ea66ffd334ea033b833f1639039ea78529e180f92a733cc1a6d974e30` |

三档截图都使用合成路由和黑色占位图，只证明布局、密度和响应式形态。它们不证明真实照片、颜色
管理、公开服务或完整产品流程。

## 安全声明

本审计没有启动可读真实 Photos Library 的生产 App Host，也没有读取、遍历或写入
`/Volumes/HDD2/Photos Library.photoslibrary` 及 `/Volumes/HDD2` 顶层四位年份文件夹。自动化证据均来自
隔离的合成 fixture。
