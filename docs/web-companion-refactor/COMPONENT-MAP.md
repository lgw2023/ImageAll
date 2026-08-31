# 组件和模块地图

## 目录边界

```text
WebCompanionApp/src
├─ app/                 # router、providers、shell、error boundary
├─ api/                 # fetch transport、session、contracts、query keys
├─ components/          # 无业务语义的通用组件
├─ features/
│  ├─ session/
│  ├─ gallery/
│  ├─ asset-viewer/
│  ├─ filters/
│  ├─ selection/
│  ├─ tags/
│  ├─ review/
│  ├─ map/
│  ├─ training/
│  ├─ slimming/
│  ├─ sources/
│  ├─ storage/
│  └─ settings/
├─ hooks/               # 真正跨 feature 的浏览器能力
├─ styles/              # tokens、reset、global utilities
├─ test/                # fixture server、builders、render harness
└─ types/               # 非 API 共享类型
```

Feature 可以依赖 `api`、`components`、`hooks`、`types`，不得读取另一 feature 的内部文件。跨功能协作通过
公开 feature entry point、URL 或 app-level workspace store。

## 全局壳组件

| 组件 | 责任 | 不负责 |
| --- | --- | --- |
| `AppProviders` | Query client、router、theme、workspace、error boundary | 业务数据预取 |
| `SessionGate` | 会话恢复、配对/登录切换、离线外壳 | 保存 Basic/token |
| `AppShell` | 顶栏、导航、主画布、检视器、活动层 | 具体 feature 状态 |
| `PrimaryNavigation` | 路由分组、当前位置、移动 sheet | API 请求 |
| `ConnectionStatus` | online/refreshing/offline/reconnecting 可访问状态 | 自己建立会话 |
| `ActivityCenter` | 长任务列表、进度、可执行后续 | 代替 Host job 状态 |
| `RouteErrorBoundary` | 局部错误、重试、回到稳定路由 | 吞掉协议错误 |

## 图库纵切片

| 组件 | 责任 |
| --- | --- |
| `GalleryRoute` | 解析 URL、组合 toolbar/grid/inspector |
| `GalleryToolbar` | 视图、排序、筛选摘要和当前主操作 |
| `FilterPanel` | schema 驱动的筛选编辑，Apply/Reset |
| `VirtualizedGallery` | 行/网格虚拟化、无限查询、滚动锚点 |
| `AssetCard` | 缩略图、最少元数据、选中/收藏状态 |
| `SelectionBar` | 数量、全选范围、批量操作入口 |
| `AssetInspector` | 当前资产详情和上下文操作 |
| `AssetViewer` | 受保护预览、全屏、键盘、预取/取消和 object URL 回收 |
| `BatchActionReview` | 提交前范围摘要、风险、可撤销性 |

## 业务工作区

| Feature | 页面/组件边界 |
| --- | --- |
| Review | `ReviewOverviewRoute`、`ReviewQueueRoute`、`ReviewDecisionBar`、`UndoNotice` |
| Map | `WorldMapRoute`、`MapCanvas`、`MapSelectionSummary`、`LocationBackfillPanel`、`PlaceTagPanel` |
| Training | `TrainingWorkspaceRoute`、`TrainingSetupForm`、`TrainingActivityList`、`SuggestionPanel` |
| Slimming | `SlimmingWorkspaceRoute`、`ThresholdEditor`、`ClusterReview`、`CleanupPlanReview`、`RecycleRequests` |
| Sources | `SourcesRoute`、`SourceList`、`SourceRequestPanel` |
| Storage | `StorageRoute`、`StorageSummary`、`MaintenanceRequestPanel` |
| Tags | `TagLibraryRoute`、`TagGroupTree`、`TagEditor`、`PresetInstaller` |
| Settings | `SettingsRoute`、`GeneralSettingsForm`、`PairingDevicesPanel` |

## 通用原语

`Button`、`IconButton`、`TextField`、`Select`、`Checkbox`、`SegmentedControl`、`Toolbar`、`Panel`、
`Dialog`、`Sheet`、`Popover`、`Tooltip`、`StatusMessage`、`Progress`、`Skeleton`、`EmptyState`、`ErrorState`、
`VisuallyHidden` 和 `SkipLink`。

原语层不接受“随意颜色”属性，只提供语义 variant；不发起 API，不存储业务状态。
