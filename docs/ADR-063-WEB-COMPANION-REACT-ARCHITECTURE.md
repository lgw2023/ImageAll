# ADR-063：Web Companion React 架构与 Host 资源契约

> 状态：已决定
>
> 日期：2026-08-31
> 相关：`ADR-048-MAC-HOST-WEB-COMPANION.md`、
> `ADR-064-WEB-COMPANION-INCREMENTAL-MIGRATION.md`、
> `web-companion-refactor/PHASE-0-AUDIT.md`

## 背景

现有 Web Companion 已形成可用且功能广泛的 Mac Host 同源网页，但实现集中在：

- `index.html`：3,366 行；
- `app.css`：16,267 行；
- `app.js`：50,176 行、1,754 个顶层函数；
- 一个包含会话、路由、查询、领域数据、选择、弹层、焦点、轮询和渲染细节的全局状态对象；
- 18 个彼此独立的 Python Playwright 脚本，共 39,629 行。

Swift Host 当前通过 `RemoteWebCompanionAssetStore.routeMap` 固定列出静态路径。它的白名单、
MIME、CSP、Cookie、Origin 和媒体边界是正确的安全起点，但无法直接承载 Vite 带哈希的产物，
也没有受限的 SPA 路由回退。

阶段零在合成数据上验证：现有浏览器主回归通过；但一次性渲染 10,000 个不可用媒体摘要会创建
10,000 张卡片和 72,410 个 DOM 节点，单次 `renderAssets()` 约 4,742 ms。该结果不是正式性能
验收，但足以证明继续扩展全量 DOM 和全局协调不是可接受的目标架构。

## 决策

### 1. 运行时和代码组织

在旧版旁新建 `WebCompanionApp/`，采用：

- Vite；
- React；
- TypeScript 严格模式；
- 按领域组织的 feature modules；
- CSS Cascade Layers、CSS Modules 与语义化 CSS 自定义属性；
- 静态构建，不引入 Node 服务端运行时。

入口只负责运行环境、Providers、路由和错误边界。任何 `App.tsx`、路由文件或 store 都不得吸收
领域业务。目标目录见 `web-companion-refactor/COMPONENT-MAP.md`。

### 2. 状态分层

状态按所有权分成五层：

1. URL/浏览历史：工作区、来源/集合、搜索、筛选、排序、视图、详情/灯箱位置；
2. Server state：Host DTO、分页、轮询、WebSocket 失效与 mutation 状态；
3. 跨路由工作区状态：选择集合、锚点、滚动恢复、面板显隐和返回焦点；
4. 持久非敏感偏好：主题、密度、三栏宽度、折叠状态；
5. 局部临时状态：菜单、表单草稿、手势和组件内部交互。

认证材料、密码、配对令牌、绝对路径和 PhotoKit identifier 不得进入 URL、持久存储、错误遥测
或开发日志。

### 3. 依赖选择

核心运行依赖限定为：

| 依赖 | 用途 | 未选方案 | 成本与约束 |
| --- | --- | --- | --- |
| React / React DOM | 组件生命周期和增量呈现 | 继续原生 DOM；Vue/Svelte | 生态成熟，但必须防止 Context 广播整个图库 |
| React Router | 嵌套路由、浏览历史和路由级恢复 | 手写 History 状态机；Hash Router | 引入路由约束；Host 必须提供受限 SPA fallback |
| TanStack Query | 请求取消、去重、重试、分页和 mutation 失效 | 自建全局请求状态 | 需要明确 query key；不得把业务规则放进缓存回调 |
| TanStack Virtual | 大图库行虚拟化 | 全量 DOM；自建窗口算法 | 需单独处理动态比例、键盘和语义位置恢复 |
| Zod | 不可信 JSON 的运行时边界校验 | 只用 TS 类型；手写校验 | DTO 较多；只在 API 边界使用，不渗入领域 |
| Lucide React | 单一 SVG 图标体系 | Emoji/Unicode；自绘全部 SVG | 包体可 tree-shake；只允许封装后的受控图标集合 |

不引入 Redux/Zustand、Tailwind、CSS-in-JS、通用后台组件库或大型动效库。只有出现可重复、可测的
需求且 reducer/context 已无法维持边界时，才以新 ADR 增加全局 store。

### 4. Host 继续是唯一事实来源

浏览器不得复制以下规则：

- GRDB/PhotoKit 数据真相；
- 来源授权和安全路径判断；
- 删除、回收、恢复和幂等规则；
- 训练、瘦身、相似分析及长任务状态机；
- 标签、审核、收藏的原子写入；
- 权限与能力门禁。

前端领域层只表达展示状态、用户意图、乐观界面限制和 Host 回包协调。所有写操作仍由现有 API、
Facade 和 Mac 原生确认完成。

### 5. 类型化 API

`Packages/ImageAllRemoteProtocol` 保持 Swift 权威 DTO。网页在 `src/api/contracts/` 建立同名、按领域
拆分的 TypeScript schema 和推导类型，并为每个已接入 endpoint 建立 fixture contract test。

当前阶段不引入跨 Swift/TypeScript 的自动代码生成器，因为 Codable 模型没有稳定 schema 输出，
未经验证的生成链会增加迁移风险。待主要 DTO 稳定后，再评估由 JSON Schema 生成双端模型。

### 6. 静态资源和路由交付

开发期新版入口为 `/web-v2/`，旧版 `/` 保持不变。Vite 使用 `/web-v2/` base，输出到
`ImageAll/Resources/WebCompanionV2/`。构建产物及 `.vite/manifest.json` 纳入 Xcode 资源目录，确保
没有 Node 的最终用户机器仍可构建和运行当前提交。

Swift 读取构建清单生成请求路径到相对文件的只读映射：

- 只接受 `/web-v2/` 下清单声明的文件；
- 静态路径只接受清单中的 ASCII 安全字符；拒绝百分号编码、反斜线及含混分隔符，再做标准化、
  符号链接解析和根目录归属校验；
- 拒绝绝对路径、空字节、`.`/`..`、反斜线逃逸、符号链接越界和未知扩展；
- MIME 由受控扩展表决定，不信任请求参数或文件内容；
- 只有声明过的应用路由可回退到新版 `index.html`；
- `/v1/*`、`/web/*`、`/world-map/*`、旧版静态路径和未知路径绝不进入 SPA fallback。

HTML、manifest、Service Worker 和 API 继续 `no-store`。带内容哈希的脚本/样式可在后续测量后使用
immutable HTTP 缓存；离线壳首先由 Service Worker 的显式 precache 白名单提供，不缓存 API、媒体、
认证或用户数据。

### 7. PWA 与媒体鉴权桥

新版 Service Worker 必须兼容旧版消息协议：

- Basic 凭据只存在页面和 Worker 内存；
- 只拦截同源 `/v1/assets/{uuid}/media` 的 GET/HEAD；
- 保留 Range；
- 不把凭据写入 Cache API、IndexedDB、localStorage 或 URL；
- 离线 precache 只包含新版公开壳和哈希静态资源；
- 离线时显示 Host 不可用和重试，不展示缓存的私人图库数据。

新版 Worker 在 `/web-v2/service-worker.js` 提供，并通过受控
`Service-Worker-Allowed: /` 获得根 scope。它替换根 scope 前必须通过旧版兼容契约测试。

### 8. 安全响应

保留并测试：

- `Secure; HttpOnly; SameSite=Strict` Cookie；
- Cookie/Basic 写请求的 Origin/Host/Sec-Fetch-Site 检查；
- 严格 CSP、`frame-ancestors`、`nosniff`、Referrer 和 Permissions Policy；
- 不把 token 放进 URL；配对 token 只来自 fragment，并在使用后清除；
- 媒体、原图和世界地图仍使用专用受保护路由；
- 前端错误只显示安全错误码和用户动作，不显示内部路径或原始异常。

开发模式不得要求放宽生产 CSP。Vite HMR 只在独立本机开发服务器使用，不由生产 Host 代理。

### 9. 性能和可访问性

图库使用行级虚拟化、稳定 asset ID、请求取消和有限预取。选择状态更新只能影响进入/离开选择的
卡片以及上下文操作，不得广播重渲染所有媒体。

WCAG 2.1 AA 是验收底线：原生语义优先、roving tabindex、可见焦点、焦点陷阱与回退、状态 live
region、44×44 CSS px 触控目标、200% 缩放、减少动态效果、高对比和 VoiceOver 人工流程均进入门禁。

## 备选方案

### 继续拆分原生 JavaScript

可降低初始迁移成本，但无法自然建立组件生命周期、类型边界、查询取消、路由嵌套和可维护的测试
夹具；现有 1,754 个函数和 1,214 个状态/配置属性已超过继续局部拆分的收益区间。拒绝。

### 一次性替换旧版

能避免双实现，但无法证明 381 条现有交互契约、复杂 Host 能力和安全桥接被完整保留，回滚成本过高。
拒绝。

### Hash Router

无需 Host fallback，但 URL 语义、深链接和浏览历史层级较差，也会继续把 fragment 同配对 token 复用。
仅作为 Host fallback 方案失败时的临时退路，不作为目标架构。

### 通用组件库或设计框架

能快速提供控件，但容易产生后台管理系统观感、额外包体和不符合照片工作台的层级。拒绝。

## 取舍

- 迁移期同时维护新旧前端，短期总成本增加；换取可回滚和逐工作流验证。
- 手写 TS schema 有同步成本；换取当前无生成链前提下可审计的运行时边界。
- 提交构建产物会增加 diff；换取 Xcode 构建不依赖最终用户安装 Node。
- 行虚拟化增加动态高度、焦点和滚动恢复复杂度；换取 10,000 项场景下受控 DOM。

## 迁移影响

- 新增前端工程、资源目录和构建验证脚本；
- `RemoteWebCompanionAssetStore` 从纯固定表扩展为“旧版固定表 + 新版清单表”；
- `RemoteHTTPServerTests` 增加路径遍历、MIME、SPA fallback、清单缺失和 bundle 完整性测试；
- 旧版 API 和页面行为保持不变，直到 ADR-064 的切换门通过。

## 回滚

迁移期回滚只需停止暴露 `/web-v2/` 或把入口指回旧版 `/`；API、数据库和 Host 业务不迁移。
默认入口切换后，`/legacy/` 至少保留一个稳定发布周期。任何 Service Worker 切换都必须提供清缓存
版本升级和旧版兼容测试，不能依赖用户手工清站点数据。

## 验证

验证门详见 `web-companion-refactor/ACCEPTANCE-GATES.md`，最低包括：类型检查、lint、格式、单元/
组件/API 契约、Playwright、视觉回归、WCAG 自动与人工、10,000 项合成性能、Swift 静态资源契约、
`build-for-testing`、CSP/Cookie/Origin 回归及三档截图。
