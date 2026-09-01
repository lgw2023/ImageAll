# 功能对齐矩阵

## 读取方法

- “Mac 现状”和“旧 Web 现状”是阶段 0 对当前源码和合成浏览器 fixture 的盘点；不表示真实照片验收。
- “新版目标”是验收契约；“迁移状态”和证据列记录 2026-09-01 当前结论。
- “API”只说明当前 Host 有相关能力；新 UI 还必须有类型解码、主/失败流程、回归和截图才能达到 `parity-proven`。
- 状态必须用本目录 README 的受控词汇。必需纵切片已在合成 Host 范围达到 `parity-proven`，根入口
  已进入 `default`；真实 Photos/文件、模型质量、WebGL 和人工 VoiceOver 仍受各行证据限制约束，
  不能由合成验收外推。

## 矩阵

| 能力 | Mac 现状 | 旧 Web 现状 | 新版目标 | API | 服务端缺口 | 迁移状态 | 测试证据 | 截图证据 | 证据限制 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 会话恢复 | 原生 Host | pair/login/refresh/logout | 单次 refresh、可解释错误、不循环 | 已有 | 无 | parity-proven | `client.test.ts`：并发 401 单次 refresh；`foundation.spec.ts`：断线恢复 | `evidence/foundation/` | 合成 401/WebSocket；不证明真实弱网时序 |
| 配对与账户登录 | 远程服务设置 | 两种入口 | 分步、键盘可用、凭据只在内存 | 已有 | 无 | parity-proven | `foundation.spec.ts`：配对→退出→账户登录，桌面+移动，秘密不持久化 | `evidence/foundation/` | 合成 Host；不证明真实账户策略或 TLS 部署 |
| 连接/离线/重连 | 原生状态 | 顶栏状态 | 不清空当前视图、指数退避、可访问文案 | WebSocket | 无 | parity-proven | `foundation.spec.ts`：事件失效、筛选/选择保留、断线重连；`pwa.spec.ts` | `evidence/foundation/` | 合成断线；未模拟跨公网抖动 |
| 图库分页 | 原生列表/网格 | 72/页、增量卡片 | infinite query + 虚拟化 + 锚点恢复 | 已有 | 无 | parity-proven | `gallery.spec.ts` + `performance.spec.ts`：10k、DOM 上限、锚点 | `evidence/gallery/`、`evidence/performance/` | 合成本地数据；不代表真实解码/网络吞吐 |
| 筛选 | 有 | 来源/文件夹/收藏/标签等 | URL 可重现、draft/apply 分离、移动 sheet | 已有 | 无 | parity-proven | `gallery.spec.ts`：q/media/favorites/source/folder URL 与 Host 请求 | `evidence/gallery/` 桌面+移动 | 移动端以紧凑折叠面板呈现，语义与作用域已验证 |
| 排序与视图 | 有 | 有并本地持久 | 可分享 sort，非敏感 density 持久 | 已有 | 无 | parity-proven | strict schema、URL state、comfortable/compact 上下文恢复 | `evidence/gallery/` | 合成资产；不外推真实排序数据正确性 |
| 选择/范围/全选 | 原生 selection | 单选、Shift、批量 | 明确已载入范围，键盘/鼠标/触控可用 | 已有 | 无 | parity-proven | `gallery.spec.ts`：单选、Shift、Meta、已载入全选、右键、框选 | `evidence/gallery/` selection bar | 全选明确限制为已载入 72 项，避免无界隐式写操作 |
| 收藏 | 有 | 批量、失败重试 | Host 结果对齐、部分失败不假成功、可见失败精确重试 | 已有 | 无 | parity-proven | `gallery.spec.ts`：Host 调和、部分失败、可见 pending/failed 计数与 `/v1/favorites/retry` 回读，桌面+移动、axe | `evidence/gallery/imageall-react-favorite-retry-chromium-{desktop,mobile}.png` | 合成 Host；不证明真实 Photos 收藏同步 |
| 单图查看/Lightbox | 原生预览 | blob、全屏、相邻预取 | overlay route、焦点返回、取消与 revoke | 已有 | 无 | parity-proven | `gallery.spec.ts` + `thumbnailLoader.test.ts`：相邻预取、取消、回收、缩放/键盘 | `evidence/gallery/imageall-react-asset-detail-chromium-desktop.png` | 合成 SVG；不证明真实色彩/解码质量 |
| iCloud-only 单图恢复 | Mac 显式获取有界预览 | 生命周期、进度、取消与旧 Host 回退 | 默认入口同样不隐式下载；Host 权威进度、取消、重试与完成后原位恢复 | 已有 | 无 | parity-proven | `gallery.spec.ts`：点击前零 POST、42% 进度、取消、重试完成、旧 Host 回退，桌面+移动、axe | `evidence/gallery/imageall-react-cloud-preview-chromium-{desktop,mobile}.png` | 只使用 409 与合成 SVG；未连接真实 Photos/iCloud，不证明真实下载吞吐 |
| 单图待审 AI 建议 | Mac 检查器直接决定 | 最多 5 条后展开、显示建议轨道 | 新默认入口显示全部 Host 建议并复用原子标签决定 | 已有 | 无 | parity-proven | `gallery.spec.ts`：6 条四轨建议、渐进展开、精确 asset/tag 决定，桌面+移动、axe | `evidence/gallery/imageall-react-pending-suggestions-chromium-{desktop,mobile}.png` | 合成详情与决定响应；不证明真实模型建议质量 |
| 当前单图即时模型 | Mac 检查器可运行标准/个人模型 | 有 `/local-suggestions` | 显式启动、轨道隔离、拒绝陈旧结果、个人结果可决定 | 已有 | 无 | parity-proven | `gallery.spec.ts`：标准/个人轨道、当前 asset 一致性、属于/不属于决定，桌面+移动、axe；Swift redacted projection | `evidence/gallery/imageall-react-local-model-chromium-{desktop,mobile}.png` | 合成模型结果；不证明真实推理、准确率或耗时 |
| 视频/媒体 Range | 原生 | 支持 GET/HEAD Range | 保持浏览器媒体语义和会话边界 | 已有 | 无 | parity-proven | Swift GET/HEAD/单 Range 与 original route 选定回归；viewer 媒体分支 | `evidence/gallery/` | 合成媒体与直接 xctest；未播放受保护真实视频 |
| 打开原片 | Mac 直接打开 | Web 请求 Host | 显示 Host 实际结果，不泄露本地路径 | 已有 | 无 | parity-proven | `gallery.spec.ts`：204 后可见确认 | `evidence/gallery/` detail | 合成 Host；不证明真实 Finder/Photos 打开 |
| 标签应用 | 有 | 批量决策、undo、新建并应用 | 预览范围、可撤销反馈、原子创建并应用冻结选区 | 已有 | 无 | parity-proven | `gallery.spec.ts`：选择汇总、批量决定、undo、单图与冻结多选 `/v1/tags/create-and-apply`、409 同名重试 operation ID 稳定 | `evidence/gallery/imageall-react-inline-tag-chromium-{desktop,mobile}.png` | 合成 Host；真实冲突/过期窗口取决于 Host |
| 标签创建/分组/归档 | 有 | 有 | 语义表单、确认与 Host 错误就地呈现 | 已有 | 无 | parity-proven | `curation.spec.ts`：创建分组、标签改名/移动；组件确认回归 | `evidence/curation/` 标签库 | 合成 Host；不证明真实大标签库维护成本 |
| 图库概览 | Mac 统计 | 独立 history route | 可定址统计、进入已筛选图库 | 已有 | 无 | parity-proven | `curation.spec.ts`：Host 统计与筛选链接 | `evidence/curation/` 概览桌面+移动 | 合成 120 项；不外推真实统计耗时 |
| 审查概览 | Mac 有来源范围、每标签上限、本地模型状态/任务和分组折叠 | 标签卡、计数、可定址来源范围和进入队列 | 补齐生成/暂停/恢复/取消、本地模型状态、每标签上限和分组语义 | 概览与精确来源参数已有；任务能力分散在 training API | 尚缺面向 Review 的统一能力投影 | in-progress | `curation.spec.ts`：全部/部分/零来源→概览计数→队列→返回，503→重试，桌面+移动、axe | `evidence/curation/imageall-react-review-source-scope-chromium-{desktop,mobile}.png` | 来源范围主路径已证明；不得外推为 Mac 审查概览全功能对齐 |
| 审查队列/连续单图/决策/undo | Mac 网格选择、Space 单图、P/X/U 连续判断、方向键、来源/密度/宽高比 | 单项/批量、连续单图、undo、与概览共享来源范围、9 档密度和缓存优先原比例 | 保留批量、范围和呈现上下文，并复用显式云预览生命周期 | 已有 | 无 | parity-proven | `curation.spec.ts`：来源范围跨路由；密度/比例 URL 恢复、原比例缩略图请求、不重拉队列/不丢当前项；单项/批量/undo；Space→U→P→自动下一张→Esc；iCloud 点击前零启动、42% 进度、切图取消、新 operation ID 重试和原位完成，桌面+移动、axe；Swift 缓存命中/正方形回退 | `evidence/curation/imageall-react-review-{source-scope,single-photo,view-controls,cloud-preview}-chromium-{desktop,mobile}.png` | 合成 8 项已证明来源、连续单图、呈现上下文和云预览生命周期；原比例只证明缓存请求/回退契约，云预览只使用 409 与 SVG，不证明真实 Photos 缓存命中或 iCloud 下载吞吐 |
| 库建议 | Mac 有 | 有 | 建议、申请、活动状态一致 | 已有 | 无 | parity-proven | `training.spec.ts`：标准/个人轨道、精确来源、job 暂停与 Host 回读 | `evidence/training/` 工作台 | 合成服务与 job；不证明真实模型推理或建议质量 |
| 世界地图查看 | Mac 地图 | 独立 route/资源 | 同源可访问地图、视口保留 | 已有 | 无 | parity-proven | `map.spec.ts`：iframe 消息桥、视口、失败重试、axe | `evidence/map/` 桌面+移动 | 合成渲染器；真实 MapLibre/WebGL 仍是人工发布检查 |
| 地图选择 | Mac 有 | 有 | 选择返回图库筛选并可后退 | 已有 | 无 | parity-proven | `map.spec.ts`：聚合选择→Host selection→范围图库→后退 | `evidence/map/` 深圳选择 | 合成 3 个聚合；不外推真实大规模聚合性能 |
| 位置回填/地方标签 | Mac 有 | 有 | 明确范围、长任务进度、失败处理 | 已有 | 无 | parity-proven | `map.spec.ts`：回填开始/Host 回读、搜索/确认地点 | `evidence/map/` 页面下方工作区 | 不证明真实元数据扫描或地理编码正确性 |
| 训练 setup | Mac 工作区 | 有 | 类型表单、前置条件、可访问错误 | 已有 | 无 | parity-proven | `training.spec.ts`：方法可用性、精确范围、503→重试、axe | `evidence/training/` 桌面+移动 | 合成 setup；不证明真实样本质量 |
| 训练 launch/activity | Mac 任务 | 有 | 非乐观 launch、activity 可恢复 | 已有 | 无 | parity-proven | `training.spec.ts`：202 后反馈、轮询、进度、取消回读 | `evidence/training/` 当前活动 | 合成活动；不证明实际训练完成、指标或模型质量 |
| 嵌入准备 | Mac 有 | 有 | 发起/取消/重试与进度 | 已有 | 无 | parity-proven | `training.spec.ts`：精确 assetIDs→进度/取消 | `evidence/training/` | 合成资产；不证明真实特征缓存生成 |
| 样本/标签库建议 | Mac 有 | 有 | 建议列表、request/action 完整闭环 | 已有 | 无 | parity-proven | `training.spec.ts`：抽检/按标签提交、范围、进度、取消、阈值投影 | `evidence/training/` | 合成模型/阈值；不证明建议正确性或真实审核写入 |
| 精简 setup/阈值 | Mac 工作区 | 有 | 受控表单、Host 回读、变更证据 | 已有 | 无 | parity-proven | `slimming.spec.ts`：来源维护、阈值回读、目录/筛选/种子 launch、重试 | `evidence/slimming/` 桌面+移动 | 合成来源和任务；不证明真实扫描、阈值效果或相似度质量 |
| 重复聚类审查 | Mac 有 | 有 | 图像对比、键盘、范围稳定 | 已有 | 无 | parity-proven | `slimming.spec.ts`：范围、代表/收藏保护、disposition、axe/无溢出 | `evidence/slimming/` 组内审查 | 合成 3 项单组；不证明真实缩略图或人工相似度正确性 |
| 清理计划/移除/回收 | Mac 安全流程 | 有 | 预览、精确数量、不乐观成功、可追踪 | 已有 | 无 | parity-proven | `slimming.spec.ts`：冻结选择、两种确认、计划→执行→验证、恢复/永久清理 | `evidence/slimming/` 清理选择与保护 | 只验证合成 Host；不证明真实文件/Photos 变更，自动测试未读取 HDD2 |
| 来源列表/管理 | Mac 侧栏/设置 | Web 有请求流 | 能力提示、审计反馈、精确作用域 | 已有 | 无 | parity-proven | `management.spec.ts`：来源刷新、Host 完成状态、axe | `evidence/management/` 来源桌面+移动 | 合成 source；不证明真实文件夹/Photos 授权 |
| 存储与维护 | Mac 设置 | Web 有 | 容量、健康、操作请求和进度 | 已有 | 无 | parity-proven | `management.spec.ts`：容量、清理确认、Host 结果 | `evidence/management/` 存储桌面+移动 | 不证明真实磁盘回收、导出或 App 重启 |
| 通知/工作区提示 | Mac 通知 | Web banner/overlay | 持久且不挡主路径，动作可追踪 | 已有 | 无 | parity-proven | `foundation.spec.ts`：Host 通知→回收站动作→投影刷新；可访问模式回归 | `evidence/foundation/` | 合成通知 |
| 通用设置 | Mac Settings | Web 有 | 类型表单、dirty/reset/save、Host 回读 | 已有 | 无 | parity-proven | `management.spec.ts`：部分更新、Host 回读、409 冲突 | `evidence/management/` 设置桌面+移动 | 合成设置；不证明真实 Mac 设置持久化 |
| 配对设备管理 | Mac 设置 | Web 有 | 撤销确认、当前设备保护 | 已有 | 无 | parity-proven | `management.spec.ts`：当前设备禁用、确认后撤销 | `evidence/management/` 设置桌面+移动 | 合成设备；不证明真实远程会话失效 |
| 长任务与操作 | Mac 任务 | Web jobs/activity | 跨路由可见、重连后恢复、操作可审计 | 已有 | 无 | parity-proven | `management.spec.ts`：进度、暂停、Host 回读；事件精确刷新 jobs | `evidence/management/` 活动桌面+移动 | 单项合成任务；不外推多任务压力 |
| 深色/对比/减少动效 | Mac 系统主题 | CSS 已有多类 media | system/light/dark、forced-colors、reduced-motion | 不需 | 无 | parity-proven | `accessibility.spec.ts`：三主题、forced-colors、reduced-motion、200% | `evidence/accessibility/` | 自动模式验证；非人工主观评估 |
| 键盘/焦点/History | Mac 原生 | 已有大量回归 | 语义 route、焦点圈定/返回、虚拟网格 roving | 不需 | 无 | parity-proven | gallery/curation/foundation E2E：History、焦点、命令面板、审查键盘、axe | 多目录截图 | 自动语义树通过；人工 VoiceOver 听读仍待发布检查 |
| PWA 外壳 | 不适用 | 有 manifest，SW 仅认证 | 可安装、公共 shell 离线，绝不缓存私有数据 | 不需 | 无 | parity-proven | `pwa.spec.ts`：离线、原子升级、清旧 cache、无私有响应 | `evidence/pwa/` | 只保证公共外壳；离线私有浏览明确禁止 |
| Swift 打包/静态资源 | App bundle folder | 固定资源表 | Vite manifest、哈希资源、受控 SPA fallback | 静态 | 无 | parity-proven | V2 manifest/路径/安全/Range 选定回归、`build-for-testing`、App bundle 精确 diff | 无 | 未启动生产 Host；裸 xctest 全类有 2 个环境持久化限制，改动相关 7/7 通过 |

## 状态更新规则

每个纵切片达到 `parity-proven` 时，必须把本表对应行的测试和截图替换为可定位的文件/报告，并在
“证据限制”中明确未覆盖范围。仅组件渲染、仅 API 200 或仅截图都不足以达标。
