# 功能对齐矩阵

## 读取方法

- “Mac 现状”和“旧 Web 现状”是阶段 0 对当前源码和合成浏览器 fixture 的盘点；不表示真实照片验收。
- “新版目标”是验收契约，不是已完成声明。
- “API”只说明当前 Host 有相关能力；新 UI 还必须有类型解码、主/失败流程、回归和截图才能达到 `parity-proven`。
- 状态必须用本目录 README 的受控词汇。工程基座已进入 `foundation`，图库、策展、管理、地图与
  训练纵切片处于 `in-progress`；未满足全部验收门的行不得提前写成 `parity-proven`。

## 矩阵

| 能力 | Mac 现状 | 旧 Web 现状 | 新版目标 | API | 服务端缺口 | 迁移状态 | 测试证据 | 截图证据 | 证据限制 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 会话恢复 | 原生 Host | pair/login/refresh/logout | 单次 refresh、可解释错误、不循环 | 已有 | 无 | foundation | `foundation.spec.ts` 合成会话/401 | `evidence/foundation/` | 未覆盖会话过期并发刷新 |
| 配对与账户登录 | 远程服务设置 | 两种入口 | 分步、键盘可用、凭据只在内存 | 已有 | 无 | foundation | `foundation.spec.ts` 未鉴权键盘入口 | 无 | 尚未证明完整提交/登出闭环 |
| 连接/离线/重连 | 原生状态 | 顶栏状态 | 不清空当前视图、指数退避、可访问文案 | WebSocket | 无 | baseline | 旧脚本回归 | 无 | 未建立新事件层 |
| 图库分页 | 原生列表/网格 | 72/页、增量卡片 | infinite query + 虚拟化 + 锚点恢复 | 已有 | 无 | in-progress | `gallery.spec.ts`：120 项/DOM 上限/500 重试 | `evidence/gallery/` 桌面+移动 | 还需 10k 性能与滚动锚点门 |
| 筛选 | 有 | 来源/文件夹/收藏/标签等 | URL 可重现、draft/apply 分离、移动 sheet | 已有 | 无 | in-progress | `gallery.spec.ts`：q/media/favorites URL 与 Host 请求 | `evidence/gallery/` toolbar | 移动端当前是折叠面板，精确 sheet 待验收 |
| 排序与视图 | 有 | 有并本地持久 | 可分享 sort，非敏感 density 持久 | 已有 | 无 | in-progress | strict schema + URL state | `evidence/gallery/` | density 尚未实现，排序交互待专项 E2E |
| 选择/范围/全选 | 原生 selection | 单选、Shift、批量 | 明确已加载/全 query 范围，键盘可用 | 已有 | 无 | in-progress | `gallery.spec.ts`：Shift 范围、虚拟 DOM、焦点返回 | `evidence/gallery/` selection bar | 还需全 query 范围与专项键盘验收 |
| 收藏 | 有 | 批量、失败重试 | 有界乐观更新、Host 结果对齐、可重试 | 已有 | 无 | in-progress | `gallery.spec.ts`：Host 状态调和、部分失败提示 | `evidence/gallery/` 卡片/详情 | retry 动作和批量部分失败仍待补齐 |
| 单图查看/Lightbox | 原生预览 | blob、全屏、相邻预取 | overlay route、焦点返回、取消与 revoke | 已有 | 无 | in-progress | `gallery.spec.ts`：detail route/dialog/关闭后焦点 | `evidence/gallery/imageall-react-asset-detail-chromium-desktop.png` | 还需相邻预取、快速切换取消、URL 回收证据 |
| 视频/媒体 Range | 原生 | 支持 GET/HEAD Range | 保持浏览器媒体语义和会话边界 | 已有 | 无 | baseline | Swift Range 测试 | 无 | 未验证新 viewer |
| 打开原片 | Mac 直接打开 | Web 请求 Host | 显示 Host 实际结果，不泄露本地路径 | 已有 | 无 | in-progress | `gallery.spec.ts`：204 后可见确认 | `evidence/gallery/` detail | 合成 Host；不证明真实 Finder/Photos 打开 |
| 标签应用 | 有 | 批量决策、undo | 预览范围、可撤销反馈、部分失败 | 已有 | 无 | in-progress | `gallery.spec.ts`：选择汇总、批量决定、undo | `evidence/gallery/` selection/detail | 冲突、过期 undo、部分失败待补齐 |
| 标签创建/分组/归档 | 有 | 有 | 语义表单、冲突/验证错误就地呈现 | 已有 | 无 | in-progress | `curation.spec.ts`：创建分组、标签改名/移动 | `evidence/curation/` 标签库 | 归档/删除确认已实现；冲突专项 E2E 待补 |
| 图库概览 | Mac 统计 | 独立 history route | 可定址统计、进入已筛选图库 | 已有 | 无 | in-progress | `curation.spec.ts`：Host 统计与筛选链接 | `evidence/curation/` 概览桌面+移动 | 合成 120 项；年份/来源深链仍待扩展 |
| 审查概览 | Mac 工作区 | 有 | 空/错/加载、进入队列 | 已有 | 无 | in-progress | `curation.spec.ts`：概览→队列、503→重试 | `evidence/curation/` 审查 | 长任务操作仍由训练/活动切片补齐 |
| 审查队列/决策/undo | Mac 工作区 | 有 | 键盘决策、安全撤销、队列刷新 | 已有 | 无 | in-progress | `curation.spec.ts`：单项/批量/A 键/undo | `evidence/curation/` 队列桌面+移动 | 冲突/过期 undo 与大队列性能待补 |
| 库建议 | Mac 有 | 有 | 建议、申请、活动状态一致 | 已有 | 无 | in-progress | `training.spec.ts`：标准/个人轨道、精确来源、job 暂停与 Host 回读 | `evidence/training/` 工作台 | 合成服务与 job；不证明真实模型推理或建议质量 |
| 世界地图查看 | Mac 地图 | 独立 route/资源 | 同源可访问地图、视口保留 | 已有 | 无 | in-progress | `map.spec.ts`：iframe 消息桥、视口宽度、503 重试、axe | `evidence/map/` 桌面+移动 | 合成渲染器；真实 MapLibre/WebGL 手工门待完成 |
| 地图选择 | Mac 有 | 有 | 选择返回图库筛选并可后退 | 已有 | 无 | in-progress | `map.spec.ts`：聚合选择→Host selection→范围图库→后退 | `evidence/map/` 深圳选择 | 合成 3 个聚合；大规模聚合性能待验收 |
| 位置回填/地方标签 | Mac 有 | 有 | 明确范围、长任务进度、失败处理 | 已有 | 无 | in-progress | `map.spec.ts`：回填开始/Host 回读、搜索/确认地点 | `evidence/map/` 页面下方工作区 | 不证明真实元数据扫描或地理编码正确性 |
| 训练 setup | Mac 工作区 | 有 | 类型表单、前置条件、可访问错误 | 已有 | 无 | in-progress | `training.spec.ts`：Host 方法可用性、标签/来源精确范围、503→重试、axe | `evidence/training/` 桌面+移动 | 合成 setup；未用真实样本验证前置条件 |
| 训练 launch/activity | Mac 任务 | 有 | 非乐观 launch、activity 可恢复 | 已有 | 无 | in-progress | `training.spec.ts`：202 后反馈、活动轮询、标签进度、取消回读 | `evidence/training/` 当前活动 | 合成活动；不证明实际训练完成、指标或模型质量 |
| 嵌入准备 | Mac 有 | 有 | 发起/取消/重试与进度 | 已有 | 无 | in-progress | `training.spec.ts`：图库选择→精确 assetIDs→工作台进度/取消 | `evidence/training/` 准备入口同设计系统 | 合成资产；不证明真实特征缓存生成 |
| 样本/标签库建议 | Mac 有 | 有 | 建议列表、request/action 完整闭环 | 已有 | 无 | in-progress | `training.spec.ts`：抽检/按标签提交、来源范围、进度、取消、阈值投影 | `evidence/training/` 工作台 | 合成模型/阈值；不证明建议正确性或真实审核写入 |
| 精简 setup/阈值 | Mac 工作区 | 有 | 受控表单、Host 回读、变更证据 | 已有 | 无 | baseline | 旧阈值回归 | 无 | 新 UI 未建 |
| 重复聚类审查 | Mac 有 | 有 | 图像对比、键盘、范围稳定 | 已有 | 无 | baseline | 旧精简脚本 | 无 | 未验证大组性能 |
| 清理计划/移除/回收 | Mac 安全流程 | 有 | 预览、精确数量、不乐观成功、可追踪 | 已有 | 无 | baseline | Swift 高风险路由测试 | 无 | 禁止真实数据自动测试 |
| 来源列表/管理 | Mac 侧栏/设置 | Web 有请求流 | 能力提示、审计反馈、精确作用域 | 已有 | 无 | in-progress | `management.spec.ts`：来源刷新、Host 完成状态、axe | `evidence/management/` 来源桌面+移动 | 合成 source；不证明真实文件夹/Photos 授权 |
| 存储与维护 | Mac 设置 | Web 有 | 容量、健康、操作请求和进度 | 已有 | 无 | in-progress | `management.spec.ts`：容量、清理确认、Host 结果 | `evidence/management/` 存储桌面+移动 | 不证明真实磁盘回收、导出或 App 重启 |
| 通知/工作区提示 | Mac 通知 | Web banner/overlay | 持久且不挡主路径，动作可追踪 | 已有 | 无 | baseline | Swift 端点测试 | 基线图有 warning | 新信息层级未建 |
| 通用设置 | Mac Settings | Web 有 | 类型表单、dirty/reset/save、Host 回读 | 已有 | 无 | in-progress | `management.spec.ts`：部分更新、Host 回读、409 冲突 | `evidence/management/` 设置桌面+移动 | 阈值仅摘要；不证明 Mac 设置持久化 |
| 配对设备管理 | Mac 设置 | Web 有 | 撤销确认、当前设备保护 | 已有 | 无 | in-progress | `management.spec.ts`：当前设备禁用、确认后撤销 | `evidence/management/` 设置桌面+移动 | 合成设备；不证明真实远程会话失效 |
| 长任务与操作 | Mac 任务 | Web jobs/activity | 跨路由可见、重连后恢复、操作可审计 | 已有 | 无 | in-progress | `management.spec.ts`：任务进度、暂停、Host 状态回读 | `evidence/management/` 活动桌面+移动 | 单项合成任务；重连恢复和多任务压力待验收 |
| 深色/对比/减少动效 | Mac 系统主题 | CSS 已有多类 media | system/light/dark、forced-colors、reduced-motion | 不需 | 无 | baseline | 旧 CSS/脚本 | 基线仅 light | 无新 token 实现 |
| 键盘/焦点/History | Mac 原生 | 已有大量回归 | 语义 route、焦点圈定/返回、虚拟网格 roving | 不需 | 无 | in-progress | `gallery.spec.ts` + `curation.spec.ts`：History、焦点返回、审查键盘、axe | `evidence/gallery/`、`evidence/curation/` | 完整键盘/VoiceOver 手工门未完成 |
| PWA 外壳 | 不适用 | 有 manifest，SW 仅认证 | 可安装、公共 shell 离线，绝不缓存私有数据 | 不需 | SW header/scope | foundation | manifest 生成检查、E2E 在线外壳 | `evidence/foundation/` | 离线、升级、Cache Storage 专项门未完成 |
| Swift 打包/静态资源 | App bundle folder | 固定资源表 | Vite manifest、哈希资源、受控 SPA fallback | 静态 | 已补 manifest delivery | in-progress | `WebCompanionV2StaticResourceTests` + App bundle hash | 无 | 全量服务器安全/Range 回归仍待最终门 |

## 状态更新规则

每个纵切片达到 `parity-proven` 时，必须把本表对应行的测试和截图替换为可定位的文件/报告，并在
“证据限制”中明确未覆盖范围。仅组件渲染、仅 API 200 或仅截图都不足以达标。
