# 验收门与切换条件

## 证据原则

默认结论是“未证明”。仅文件存在、仅构建成功、仅一张截图、仅 API 200、仅合成 DOM 或仅旧版回归
都不能证明新版完成。每项必须有与声明范围匹配的当前产物、测试或运行时证据。

## A. 每个纵切片的完成门

- [x] 功能矩阵中 Mac/旧 Web/新版/API/缺口已对齐。
- [x] 有可通过 `/web-v2/` 实际访问的用户动作 → Host 处理 → 可见结果闭环。
- [x] Zod/TypeScript 契约覆盖所用 Host DTO，且有有效/无效 fixture。
- [x] 一条主路径、一条必要失败路径、适用回归通过。
- [x] 键盘、焦点、History 和移动响应式不退化。
- [x] 桌面/紧凑/移动截图已审阅，限制已记录。
- [x] 错误、空、加载、部分成功、会话失效定义完整。
- [x] 类型检查、lint、format check、相关单元/组件/E2E 和 `git diff --check` 通过。
- [x] 未读取、遍历或写入受保护真实数据。

## B. 工程基座门

- [x] Vite + React + strict TypeScript 工程可重现安装，lockfile 已提交。
- [x] `build`、`typecheck`、`lint`、`format:check`、`test`、`test:e2e` 脚本有明确语义。
- [x] ESLint 不通过全局 disable 或大面积 `any` 获得绿色。
- [x] 生产构建产物写入 `ImageAll/Resources/WebCompanionV2`，不要求最终用户的 Xcode 构建机安装 Node。
- [x] 构建清单与实际文件一致，不存在清单外可访问资源或缺失引用。

## C. 安全、隐私和数据一致性门

- [x] 现有 CSP 限制不降级，无 `unsafe-inline`、`unsafe-eval`、无不必要跨源。
- [x] Cookie 仍是 Secure/HttpOnly/SameSite=Strict，Basic 仍只在内存，配对秘密不进入 query/log/storage。
- [x] Cookie/Basic 变更继续要求匹配 Origin/Host/Sec-Fetch-Site；跨源和缺失证据请求被拒绝。
- [x] `/v1/*`、未知文件、路径穿越、双重编码、反斜杠不被 SPA fallback 或静态 store 接受。
- [x] 媒体 GET/HEAD/Range、WebSocket 鉴权和会话 refresh 回归通过。
- [x] Cache Storage/HTTP cache/SW 不包含 API、缩略图、预览、媒体、token 或用户元数据。
- [x] 高风险操作以 Host 权威结果为准，不乐观宣告成功，不改写 GRDB/PhotoKit 原子性语义。
- [x] 无自动化测试读取/遍历/写入 HDD2 受保护路径，无生产 App Host 真实数据测试。

## D. 可访问性与响应式门

- [x] 关键页 axe 无 serious/critical，普通文本对比至少 4.5:1，关键非文本边界至少 3:1。
- [x] 全功能可用键盘完成；焦点可见、无陷阱、dialog/sheet 关闭后返回合理位置。
- [x] 网格/虚拟列表提供可理解的语义、位置和选中状态。
- [x] 触控命中区至少 44×44 px；390×844 无水平滚动、主操作不被 safe area 遮挡。
- [x] 1440×960、1024×768、390×844 主路径通过，light/dark/system 无信息丢失。
- [x] reduced-motion、forced-colors、200% zoom 和文字放大通过自动化模式清单。
- [ ] VoiceOver 手工记录覆盖页标题、导航、图库、查看器、选择、进度、错误。

## E. 大图库性能门

基准环境在报告中固定浏览器、机型、视口、构建模式和 fixture hash。门槛是产品目标，如实测显示需调整，必须
用 ADR/证据说明，不静默放宽：

- [x] 10,000 条数据时 DOM 节点稳态 `< 2,500`，资产卡片 DOM `< 300`。
- [x] 生产构建下首页从 route 进入到可选择首张卡片 `< 1,500 ms`（本地 fixture）。
- [x] 单选可见反馈 p95 `< 100 ms`，打开 viewer p95 `< 250 ms` 不含人为网络延迟。
- [x] 程序滚动测量中长任务 `> 50 ms` 的次数不超过 3，无持续空白/跳动。
- [x] 快速滚动/切换 asset 后旧请求被取消，预取并发有上限，关闭 viewer 后 object URL 回到基线。
- [x] 返回图库后恢复 anchor 且偏差不超过一行，焦点不丢失。

## F. PWA 门

- [x] manifest 名称、icons、`start_url`、`scope`、display、theme/background colors 通过自动检查。
- [x] Service Worker 仅预缓存带内容 hash 的公共 shell，安装失败不破坏在线主路径。
- [x] 无网时显示无私有内容的外壳和恢复指引，不显示过期照片/元数据。
- [x] 旧 Service Worker 消息协议、新版 activate/claim、版本升级和清旧 cache 都有回归。
- [x] 用户不需手工清缓存、重启 App 或重新配对来完成新旧版切换。

## G. Swift Host 和 App 打包门

- [x] manifest 资源表测试覆盖哈希 JS/CSS/font/icon、MIME、HEAD、缺失文件和 bundle 不一致。
- [x] SPA fallback 测试覆盖已知 route、未知 route、带点文件名、`/v1/*`、编码路径穿越。
- [x] `RemoteHTTPServerTests` 中新版契约不依赖 minified bundle 内部函数名。
- [x] 改动相关 Swift 单测、服务器回归、协议包测试和 `build-for-testing` 通过。
- [x] 构建 App bundle 中 `WebCompanionV2` 与仓库产物逐文件一致，manifest SHA-256 一致。
- [x] 打包测试不启动可读真实照片的生产远程 Host。

## H. 切换默认入口前

- [x] 功能矩阵所有必需行为 `parity-proven`，无未处理 `server-gap`。
- [ ] A–G 的工程自动化已通过；D 中人工 VoiceOver 听读仍需项目所有者在发布环境记录。
- [x] 新版完成一轮干净的全量本地稳定验证，未发现阻塞主流程的回归。
- [x] `/legacy/` 可从新版可见入口进入；因旧版不解析新版 URL，入口经决策明确从旧版默认状态开始且不传敏感上下文。
- [x] 默认入口切换为单独本地提交，回滚只需恢复入口/资源版本，不动数据库 migration。
- [x] 中文交付说明包含已完成、未完成、测试命令、证据限制、截图、提交和回滚步骤。

## I. 删除旧实现前

- [ ] 默认切换后至少经过一个明确记录的稳定发布周期。
- [ ] 代码、测试、文档、Xcode resources、Service Worker、CSP 和路由对旧文件/函数的引用已穷尽检查。
- [ ] 已保留必要的审计证据，旧浏览器测试中仍有价值的行为契约已迁移。
- [ ] 旧版删除为单独本地提交，不夹带新功能，可通过 Git 恢复。
- [ ] 删除后重跑 B–H 中所有适用门，不以“编译通过”代替运行时验证。

当前明确保留旧版，不执行 I：至少等待一个稳定发布周期，并先补齐人工 VoiceOver 与真实发布环境
MapLibre/Host 验收。旧版保留入口为 `/legacy/`，默认入口回滚提交为 `66284a2a`。
