# 路由与状态模型

## 状态归属原则

| 层 | 例子 | 权威位置 | 生命周期 |
| --- | --- | --- | --- |
| URL/History | route、sort、view、已应用筛选、asset overlay | React Router | 可刷新/可前进后退 |
| Server state | assets、tags、jobs、review queue、settings | Swift Host + TanStack Query cache | 按 stale/invalidation 策略 |
| Workspace | selection IDs、anchor、inspector open、待撤销 token | app-level store/reducer | 当前 tab 会话 |
| Persistent preference | theme、grid density、sidebar width/collapse | versioned localStorage adapter | 跨会话，只存非敏感值 |
| Ephemeral UI | hover、popover、draft field、pending focus target | component state | 组件生命周期 |

不引入第二个全局大对象。一个值如果能从 URL 或 server response 完全派生，就不额外存储。

## 路由契约

- 每个顶层工作区是独立 route module。路由级 `loader` 不直接修改 Host，写操作只经显式 mutation。
- 单张资产查看是可定址 overlay route；背景 location 保留图库查询、选择和滚动锚点。
- 未知 `/web-v2/*` 路由显示应用内 404；Swift 只为已知无扩展名路由回退到 shell。
- 新版内部路由只传递允许列表中的 route、sort、view、source/folder 和筛选，不传凭据或 payload。
  旧版不解析新版 URL，`/legacy/` 因此明确从旧版默认状态开始，不伪造无损上下文桥。

## 图库状态机

```text
route entered
  ├─ session unavailable → SessionGate
  └─ session ready
       ├─ query pending → skeleton preserving layout
       ├─ query error   → scoped retry / session recovery
       └─ query ready
            ├─ browsing
            ├─ selecting → selection bar
            ├─ viewing asset → overlay route
            └─ mutating → optimistic only when Host contract permits
```

选择集是 `Set<AssetID>` 语义，顺序与当前 query 分开。Shift 范围选择使用当前稳定排序和 anchor；数据刷新后
不存在的 ID 被剪枝并向用户说明。“全选”必须区分已加载项与整个 server query 范围，不能用视觉错觉混淆。

## 服务端缓存和事件

- Query key 由 domain + versioned normalized parameters 构成，不把不稳定对象直接放入 key。
- WebSocket 事件先经 schema 解码，再精确 `invalidateQueries` 或更新已知实体；未知事件记录类型，不崩溃。
- Mutation 成功以 Host response 为准。只有可逆且契约清晰的收藏/局部标签状态可做乐观更新；
  精简、删除、来源维护、训练启动不做乐观成功。
- 会话 refresh 最多合并为一个 in-flight promise，其他 401 请求等待结果；失败后进入 SessionGate，不循环重试。

## 缓存与隐私

localStorage 允许键：`clientID`（配对指纹的随机非秘密标识）、`theme`、`galleryDensity`、
`sidebarCollapsed`、`inspectorWidth`，后续增加必须经 ADR/规格评审。sessionStorage 也不用于 token、
密码、媒体 blob 或 API 实体。TanStack Query 不启用持久化插件。

## 滚动、焦点和恢复

- 每个图库 query 用稳定的 location key 保存 `{anchorAssetID, offsetWithinRow}`，不保存巨大 pixel offset。
- 关闭 asset overlay 后焦点回到原卡片；如卡片已离开结果集，回到主标题并说明。
- 路由前进/后退恢复已应用筛选、overlay 和滚动；草稿表单不跨路由暗中恢复。
- 虚拟化的 roving tabindex 只保留一个网格卡片在 tab order，但程序滚动不产生不必要动画。
