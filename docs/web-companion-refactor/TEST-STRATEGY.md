# 测试策略

## 总原则

测试证明具体契约，不用数量堆叠代替纵向闭环。每个新能力保留一条真实用户主路径、一条必要失败路径和
与旧稳定契约相关的回归。所有自动化使用合成 fixture，不启动可读真实 Photos Library 的生产 Host。

## 分层

| 层 | 工具 | 覆盖 | 失败定位 |
| --- | --- | --- | --- |
| 类型/静态 | `tsc --noEmit`、ESLint、Prettier | strict TS、hooks、import 边界、风格 | 源文件 |
| 单元 | Vitest | schema、query normalization、reducers、formatters、state machines | 纯函数/模块 |
| 组件 | Testing Library + user-event + axe | 语义 DOM、键盘、焦点、表单、加载/空/错 | 组件 |
| API 契约 | Vitest + 黄金 JSON | Swift DTO 编码结果可被 Zod 解码 | 端点/schema |
| 浏览器 E2E | Playwright Test | 合成 Host 下的真实 route/fetch/blob/History/SW | 用户流程 |
| 视觉 | Playwright screenshot | 1440×960、1024×768、390×844，light/dark，关键状态 | 像素差异 + artifact |
| 性能 | Playwright + Performance API | 10,000 条虚拟化、滚动、选择、查看 | 性能报告/trace |
| Swift Host | XCTest | manifest、MIME、fallback、CSP、Origin、Cookie、Range、bundle | Host 契约 |
| 打包 | `xcodebuild build-for-testing` + 定向 test | 构建产物真正进 App bundle 且可服务 | App bundle/运行时 |

## Fixture 安全

- 合成 ID、文件名、位置、时间、标签和任务不得从真实库导出。
- 图像 fixture 是仓库内小型生成图或运行时 canvas/SVG，不复制个人照片。
- 测试 server 只绑定 loopback 随机端口，记录请求计数不记录凭据/body。
- 测试启动前断言任何 fixture/output root 都不在 `/Volumes/HDD2`，也不在 `.photoslibrary` 包中。
- 清理只针对测试自己创建且已校验的临时目录，不遍历受保护路径。

## 组件和 API 核心用例

1. `SessionGate`：refresh 成功、refresh 失败进入登录、多个 401 只一个 refresh。
2. `VirtualizedGallery`：空列表、首页、加载下页、query 更换、卡片数不等于 DOM 数。
3. `SelectionBar`：单选、Shift 范围、已载入范围全选文案和变更后剪枝；在 Host 没有显式
   query-selection 协议时不提供无界全 query 写操作。
4. `AssetViewer`：进入/退出焦点、相邻预取上限、快速导航取消、object URL revoke。
5. 写操作：Host 完全成功、部分成功、冲突、会话失效、无法撤销；界面不得仅显示假成功 toast。
6. schema：最小有效、完整、未知字段、缺必需字段、未知枚举和协议错误。

## 端到端纵切片

| 切片 | 主路径 | 必要失败 |
| --- | --- | --- |
| 会话+图库 | refresh → 加载 → 筛选 → 查看 → 返回锚点 | refresh 失败、图库 500 重试 |
| 选择+收藏 | Shift 选择 → 批量收藏 → Host 结果调和 | 部分失败与 retry |
| 标签 | 选择 → 预览 → 应用 → undo | 冲突/过期 undo |
| 审查 | 概览 → 队列 → 键盘决策 → undo | 队列刷新和部分失败 |
| 地图 | 加载 → 选择区域 → 图库范围 → 后退 | snapshot 失败/无位置 |
| 训练 | setup → launch → activity 进度 → action | 前置不满足/launch 拒绝 |
| 精简 | setup → 阈值 → cluster review → cleanup plan | 计划已过期/部分移除 |
| 来源/存储/设置 | 读取 → 编辑/请求 → Host 回读 | capability 不支持/冲突 |

## 视觉回归

- 基线图和差异图进 Git；trace、video 和临时产物可作 CI artifact，不默认进 Git。
- 对时间、动画、随机 ID 和图像 fixture 做确定性处理，不用巨大 mask 隐藏真实差异。
- 每个主纵切片有一组桌面/紧凑/移动截图；对深色、焦点、错误和高风险确认增加专项图。
- 差异阈值必须紧且有原因；不为了通过而全局提高阈值。更新基线时连同评审说明一起提交。

## 10,000 条性能场景

固定生成 10,000 条元数据、小图占位和可重现筛选结果。在 Chromium 中记录：

- 可见卡片和 DOM 节点数；
- 首次可交互、从顶部到中部的滚动帧耗时；
- 单选、Shift 范围、打开 viewer、返回锚点的响应时间；
- 预取数、取消数、object URL 活跃数；
- 稳态 heap 只作趋势证据，不在未固定浏览器/机型时声称绝对内存保证。

门槛见 [ACCEPTANCE-GATES.md](ACCEPTANCE-GATES.md)。

## 可访问性

- 每个 route 运行 axe，不允许 serious/critical；对深色、移动 sheet、dialog 和错误状态单独扫描。
- 手工键盘验收需记录：从 skip link 进入、图库导航、选择、viewer、dialog、路由后退。
- VoiceOver 验收记录页标题/区域、网格位置、选中状态、连接状态、进度和错误。
- 200% 缩放、系统文字放大、forced colors 和 reduced motion 作为单独人工清单。
