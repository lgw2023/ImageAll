# 功能对齐矩阵

## 读取方法

- “Mac 现状”和“旧 Web 现状”是阶段 0 对当前源码和合成浏览器 fixture 的盘点；不表示真实照片验收。
- “新版目标”是验收契约，不是已完成声明。
- “API”只说明当前 Host 有相关能力；新 UI 还必须有类型解码、主/失败流程、回归和截图才能达到 `parity-proven`。
- 状态必须用本目录 README 的受控词汇。本版仍处于 `baseline`。

## 矩阵

| 能力 | Mac 现状 | 旧 Web 现状 | 新版目标 | API | 服务端缺口 | 迁移状态 | 测试证据 | 截图证据 | 证据限制 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 会话恢复 | 原生 Host | pair/login/refresh/logout | 单次 refresh、可解释错误、不循环 | 已有 | 无 | baseline | Swift 会话测试 | 无 | 新 UI 未验证 |
| 配对与账户登录 | 远程服务设置 | 两种入口 | 分步、键盘可用、凭据只在内存 | 已有 | 无 | baseline | Swift 鉴权回归 | 无 | 未做端到端 |
| 连接/离线/重连 | 原生状态 | 顶栏状态 | 不清空当前视图、指数退避、可访问文案 | WebSocket | 无 | baseline | 旧脚本回归 | 无 | 未建立新事件层 |
| 图库分页 | 原生列表/网格 | 72/页、增量卡片 | infinite query + 虚拟化 + 锚点恢复 | 已有 | 无 | baseline | 旧全流程通过 | 三档图库基线 | 旧版 10k DOM 不受控 |
| 筛选 | 有 | 来源/文件夹/收藏/标签等 | URL 可重现、draft/apply 分离、移动 sheet | 已有 | 无 | baseline | 旧筛选 flow 通过 | 基线图可见 toolbar | 只证明旧契约 |
| 排序与视图 | 有 | 有并本地持久 | 可分享 sort，非敏感 density 持久 | 已有 | 无 | baseline | 旧脚本 | 基线图 | 新 URL 未验证 |
| 选择/范围/全选 | 原生 selection | 单选、Shift、批量 | 明确已加载/全 query 范围，键盘可用 | 已有 | 无 | baseline | 旧交互脚本 | 移动基线 | 虚拟化选择未证明 |
| 收藏 | 有 | 批量、失败重试 | 有界乐观更新、Host 结果对齐、可重试 | 已有 | 无 | baseline | 旧 flow 包含 13 次收藏 | 无 | 未验证新 cache 调和 |
| 单图查看/Lightbox | 原生预览 | blob、全屏、相邻预取 | overlay route、焦点返回、取消与 revoke | 已有 | 无 | baseline | 旧 lightbox flow 通过 | 无 | 只用合成黑图 |
| 视频/媒体 Range | 原生 | 支持 GET/HEAD Range | 保持浏览器媒体语义和会话边界 | 已有 | 无 | baseline | Swift Range 测试 | 无 | 未验证新 viewer |
| 打开原片 | Mac 直接打开 | Web 请求 Host | 显示 Host 实际结果，不泄露本地路径 | 已有 | 无 | baseline | Swift route 测试 | 无 | 新 UI 未证明 |
| 标签应用 | 有 | 批量决策、undo | 预览范围、可撤销反馈、部分失败 | 已有 | 无 | baseline | 旧 flow 11 次决策 | 无 | 新批处理未验证 |
| 标签创建/分组/归档 | 有 | 有 | 语义表单、冲突/验证错误就地呈现 | 已有 | 无 | baseline | Swift + 旧脚本 | 无 | 未做新表单 |
| 图库概览 | Mac 统计 | 独立 history route | 可定址统计、进入已筛选图库 | 已有 | 无 | baseline | 旧 route 回归 | 无 | 新可视化未验证 |
| 审查概览 | Mac 工作区 | 有 | 空/错/加载、进入队列 | 已有 | 无 | baseline | 旧 flow 通过 | 无 | 新 route 未建 |
| 审查队列/决策/undo | Mac 工作区 | 有 | 键盘决策、安全撤销、队列刷新 | 已有 | 无 | baseline | 旧 flow 3 次决策 | 无 | 新焦点契约未证明 |
| 库建议 | Mac 有 | 有 | 建议、申请、活动状态一致 | 已有 | 无 | baseline | Swift 端点测试 | 无 | 新 UI 未建 |
| 世界地图查看 | Mac 地图 | 独立 route/资源 | 同源可访问地图、视口保留 | 已有 | 可能需构建资源整合 | baseline | 旧地图脚本 | 无 | 新地图方案未证明 |
| 地图选择 | Mac 有 | 有 | 选择返回图库筛选并可后退 | 已有 | 无 | baseline | Swift/legacy 测试 | 无 | 新路由桥未建 |
| 位置回填/地方标签 | Mac 有 | 有 | 明确范围、长任务进度、失败处理 | 已有 | 无 | baseline | Swift route 测试 | 无 | 未验证新 activity |
| 训练 setup | Mac 工作区 | 有 | 类型表单、前置条件、可访问错误 | 已有 | 无 | baseline | 旧训练脚本 | 无 | 新表单未建 |
| 训练 launch/activity | Mac 任务 | 有 | 非乐观 launch、activity 可恢复 | 已有 | 无 | baseline | Swift + 旧脚本 | 无 | 未做新长任务 |
| 嵌入准备 | Mac 有 | 有 | 发起/取消/重试与进度 | 已有 | 无 | baseline | Swift 端点测试 | 无 | 新 UI 未建 |
| 样本/标签库建议 | Mac 有 | 有 | 建议列表、request/action 完整闭环 | 已有 | 无 | baseline | Swift 端点测试 | 无 | 新 UI 未建 |
| 精简 setup/阈值 | Mac 工作区 | 有 | 受控表单、Host 回读、变更证据 | 已有 | 无 | baseline | 旧阈值回归 | 无 | 新 UI 未建 |
| 重复聚类审查 | Mac 有 | 有 | 图像对比、键盘、范围稳定 | 已有 | 无 | baseline | 旧精简脚本 | 无 | 未验证大组性能 |
| 清理计划/移除/回收 | Mac 安全流程 | 有 | 预览、精确数量、不乐观成功、可追踪 | 已有 | 无 | baseline | Swift 高风险路由测试 | 无 | 禁止真实数据自动测试 |
| 来源列表/管理 | Mac 侧栏/设置 | Web 有请求流 | 能力提示、审计反馈、精确作用域 | 已有 | 无 | baseline | 旧 flow 12 次来源操作 | 无 | 只用合成 source |
| 存储与维护 | Mac 设置 | Web 有 | 容量、健康、操作请求和进度 | 已有 | 无 | baseline | 旧 flow 1 次存储请求 | 无 | 不证明真实磁盘操作 |
| 通知/工作区提示 | Mac 通知 | Web banner/overlay | 持久且不挡主路径，动作可追踪 | 已有 | 无 | baseline | Swift 端点测试 | 基线图有 warning | 新信息层级未建 |
| 通用设置 | Mac Settings | Web 有 | 类型表单、dirty/reset/save、Host 回读 | 已有 | 无 | baseline | Swift 设置测试 | 无 | 新 UI 未建 |
| 配对设备管理 | Mac 设置 | Web 有 | 撤销确认、当前设备保护 | 已有 | 无 | baseline | Swift route 测试 | 无 | 新 UI 未建 |
| 长任务与操作 | Mac 任务 | Web jobs/activity | 跨路由可见、重连后恢复、操作可审计 | 已有 | 无 | baseline | Swift jobs 测试 | 无 | 新 activity center 未建 |
| 深色/对比/减少动效 | Mac 系统主题 | CSS 已有多类 media | system/light/dark、forced-colors、reduced-motion | 不需 | 无 | baseline | 旧 CSS/脚本 | 基线仅 light | 无新 token 实现 |
| 键盘/焦点/History | Mac 原生 | 已有大量回归 | 语义 route、焦点圈定/返回、虚拟网格 roving | 不需 | 无 | baseline | 旧 focus/history 脚本 | 无 | 新虚拟化仍是高风险 |
| PWA 外壳 | 不适用 | 有 manifest，SW 仅认证 | 可安装、公共 shell 离线，绝不缓存私有数据 | 不需 | SW header/scope | baseline | 旧 SW 测试 | 无 | 新缓存策略未实现 |
| Swift 打包/静态资源 | App bundle folder | 固定资源表 | Vite manifest、哈希资源、受控 SPA fallback | 静态 | 明确缺口 | baseline | 旧 Swift 资源测试 | 无 | 是基座阻塞项 |

## 状态更新规则

每个纵切片达到 `parity-proven` 时，必须把本表对应行的测试和截图替换为可定位的文件/报告，并在
“证据限制”中明确未覆盖范围。仅组件渲染、仅 API 200 或仅截图都不足以达标。
