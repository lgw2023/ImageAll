# Host API 清单

## 边界和类型源

Host 依然是权威业务层。路径由
`Packages/ImageAllRemoteProtocol/Sources/ImageAllRemoteProtocol/RemoteError.swift` 的 `RemoteHTTPPaths`
定义，DTO 位于同一 Swift package，路由和安全策略由
`ImageAll/Infrastructure/Remote/RemoteHTTPServer.swift` 实现。

新前端不复制 Host 业务规则。TypeScript schema 是跨语言解码边界，不是第二份业务规范。

## 会话、配对与事件

| Method | Path | 用途 | 认证/安全 |
| --- | --- | --- | --- |
| POST | `/web/session/pair` | 配对换取会话 | 公开配对边界，秘密来自 fragment |
| POST | `/web/account/login` | 账户/Basic 登录 | 凭据仅在当前客户端内存 |
| GET | `/web/session` | 当前会话状态 | Cookie 或 Basic 鉴权 |
| POST | `/web/session/refresh` | 刷新会话 | 允许在会话恢复窗口中调用 |
| POST | `/web/session/logout` | 注销 | Cookie/Basic 变更校验 Origin/Host |
| GET | `/v1/pairing/offer` | 当前配对提示 | 已鉴权 |
| POST | `/v1/pairing/complete` | 完成配对 | 特定未鉴权路径 |
| POST | `/v1/pairing/token` | 刷新配对 token | 特定未鉴权路径 |
| GET/DELETE | `/v1/pairing/devices[/:id]` | 列表/撤销设备 | 已鉴权；DELETE 是变更 |
| GET Upgrade | `/v1/events/websocket` | 任务/数据变更推送 | 独立 WebSocket 鉴权 |

## 资产、图像和图库

| Method | Path | 用途 | DTO/语义 |
| --- | --- | --- | --- |
| GET | `/v1/assets` | 分页、筛选、排序的资产摘要 | `RemoteAssetDTO.swift` |
| GET | `/v1/assets/:id` | 资产详情 | `RemoteAssetDetailDTO.swift` |
| GET/HEAD | `/v1/assets/:id/thumbnail` | 缩略图 | 受保护图像响应 |
| GET/HEAD | `/v1/assets/:id/preview` | 本地预览 | 受保护图像响应 |
| GET/HEAD | `/v1/assets/:id/media` | 媒体流 | Range/Content-Range |
| POST | `/v1/assets/:id/cloud-preview[...]` | 申请/取消云预览 | `RemoteCloudPreviewDTO.swift` |
| POST | `/v1/assets/:id/open-original` | 请求 Host 打开原片 | Host 执行，Web 不接触路径 |
| GET | `/v1/gallery-overview` | 图库概览统计 | `RemoteGalleryOverviewDTO.swift` |
| POST | `/v1/favorites` | 收藏变更 | 批量请求/返回实际结果 |
| POST | `/v1/favorites/retry` | 重试收藏同步 | 已有 Host 能力 |
| GET | `/v1/source-folders` | 来源文件夹分页 | `RemoteSourceDTO.swift` |

## 标签、选择与审查

| Method | Path | 用途 |
| --- | --- | --- |
| GET | `/v1/tags` | 标签列表 |
| POST | `/v1/tags` 动态路由 | 重命名、归档、移动 |
| POST | `/v1/tags/install-presets` | 安装预置 |
| GET/POST | `/v1/tag-groups` | 列表/创建分组 |
| POST | `/v1/tag-groups/:id/...` | 重命名/删除分组 |
| POST | `/v1/tag-decisions/batch` | 批量应用标签决策 |
| POST | `/v1/tag-decisions/undo` | 撤销标签决策 |
| POST | `/v1/tags/create-and-apply` | 创建并应用标签 |
| POST | `/v1/tags/selection` | 保存选择范围的标签 |
| GET | `/v1/review/overview` | 审查概览 |
| GET | `/v1/review/queue` | 审查队列 |
| POST | `/v1/review/decisions/batch` | 批量审查决策 |
| POST | `/v1/review/decisions/undo` | 撤销审查决策 |

主要类型源：`RemoteTagDTO.swift`、`RemoteReviewDTO.swift`。

## 地图、训练与精简

| 领域 | 端点组 | 类型源 |
| --- | --- | --- |
| 世界地图 | `GET /v1/world-map/snapshot`，`POST /selection`，backfill 读/写，place-tags 读/写 | `RemoteWorldMapDTO.swift` |
| 训练 | workspace、setup、launch、activities 及 activity action | `RemoteTrainingDTO.swift` |
| 嵌入准备 | 状态、request、operation action | `RemoteTrainingDTO.swift` |
| 样本建议 | 列表、request、operation action | `RemoteTrainingDTO.swift` |
| 标签库建议 | 列表、request、operation action | `RemoteTrainingDTO.swift` |
| 图库精简 | workspace、setup、source-maintenance、launch、thresholds、cluster-review | `RemoteLibrarySlimmingDTO.swift` |
| 精简清理 | recycle 读/请求、removals 读/写、identical cleanup plan/request、job action | `RemoteLibrarySlimmingDTO.swift` |

## 来源、存储、通知与设置

| Method | Path | 类型源 |
| --- | --- | --- |
| GET | `/v1/capabilities` | `RemoteCapabilities.swift` |
| GET | `/v1/sources` | `RemoteSourceDTO.swift` |
| GET/POST | `/v1/source-management[ /requests]` | `RemoteSourceManagementDTO.swift` |
| GET/POST | `/v1/storage-maintenance[ /requests]` | `RemoteStorageMaintenanceDTO.swift` |
| GET/POST | `/v1/workspace-notice[ /dismiss|/action]` | `RemoteWorkspaceNoticeDTO.swift` |
| GET/PUT | `/v1/settings/general` | `RemoteGeneralSettingsDTO.swift` |
| GET | `/v1/jobs` | `RemoteJobDTO.swift` |
| POST | `/v1/jobs/:id/action` | `RemoteJobDTO.swift` |

## 前端迁移所需的 Host 增量

功能 API 未发现阻塞当前迁移的硬缺口。已确认的 Host 工作主要是静态交付能力：

1. 从固定文件表扩展为构建清单驱动的 `/web-v2/` 资源表。
2. 只对已知新前端路由提供 `index.html` fallback，阻止路径穿越、未知扩展和 `/v1/*` 覆盖。
3. 为新 Service Worker 返回经审核的 `Service-Worker-Allowed: /`，但私有资源仍 `no-store`。
4. 在 Swift 测试中用 manifest/bundle 契约替代对 React 构建产物内部函数名的字符串耦合。

如果迁移中出现功能缺口，必须先在功能矩阵标记 `server-gap`，补齐 Swift protocol/DTO/测试后才能在
新 Web 中标记完成，不允许用前端猜测或虚假成功填平。
