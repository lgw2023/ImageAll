# API 与 TypeScript 类型模型

## 契约策略

1. Swift `ImageAllRemoteProtocol` 是协议语义的权威源。
2. `src/api/contracts` 按 Swift DTO 手写 Zod schema，并从 schema 推导 TypeScript 类型。
3. 任何 `response.json()` 不得用 `as T` 跳过解码；时间、UUID、枚举和 nullable 字段在边界验证。
4. 未知字段可向前兼容，未知枚举不得静默当成默认操作。
5. 合成 fixture 同时在 Swift encoder 和 TypeScript decoder 两端检查，为每个领域保留一份最小黄金 JSON。

## 目录

```text
src/api
├─ client.ts              # same-origin transport、headers、abort、one refresh retry
├─ errors.ts              # 协议/网络/鉴权/取消错误
├─ session.ts             # pair/login/refresh/logout 协调
├─ media.ts               # protected blob/object URL 生命周期
├─ events.ts              # WebSocket、backoff、event decode
├─ queryKeys.ts
└─ contracts/
   ├─ common.ts
   ├─ asset.ts
   ├─ tag.ts
   ├─ review.ts
   ├─ map.ts
   ├─ training.ts
   ├─ slimming.ts
   ├─ source.ts
   ├─ storage.ts
   ├─ settings.ts
   └─ event.ts
```

## 运输契约

`request(schema, input)` 必须：

- 默认 `credentials: "same-origin"`，设置 `Accept: application/json`。
- 仅在内存中存在 Basic 时加 Authorization；不打印 header/body 中的敏感内容。
- 支持上层 `AbortSignal`，将主动取消与网络错误区分。
- 401 只允许一次共享 refresh 和一次原请求重放；配对/登录/refresh/logout 本身不重放。
- 在解码前检查 status/content-type；204 与 JSON 结果分开。
- 将 Host 协议错误解码为 `RemoteProblem { code, message, details?, retryable? }`，界面根据 code 决定后续，
  不使用字符串匹配业务逻辑。

## 身份和时间

- UUID 在网络边界验证形式，在内部使用 branded string，防止 AssetID/TagID/JobID 混用。
- Host 发送的时间单位必须在对应 Swift DTO 和 fixture 中注明；不用数值大小猜毫秒/秒。
- 文件容量保留整数 byte，展示层再格式化；阈值和百分比保留 Host 单位。

## 媒体契约

`media.ts` 将 `{url, revoke, abort}` 作为一个可处置资源：离开可见窗口、切换 asset、路由卸载或会话失效
时必须 abort fetch 并 revoke object URL。缩略图、预览和媒体端点不进 Query 持久缓存、Cache Storage
或 localStorage。

## 事件契约

- 连接状态：`idle → connecting → open → reconnecting → closed`。指数退避有上限和 jitter，online/visibility 恢复可提前重连。
- 事件 envelope 至少包含 protocol version/type；已知 payload 分支严格解码。
- 事件只表示“需要取新”时就 invalidate，不根据不完整 payload 组装权威实体。
- 连接中断不清空当前可见数据，界面显示可能过期；会话明确失效才进入重新认证。

## 版本和差异审计

- 新增/改动 Swift DTO 时，同一提交更新 Zod schema、fixture 和契约测试。
- 可选字段的原因必须明确（老 Host 兼容、业务可空或分页省略），不使用大面积 `.optional()` 消除错误。
- protocol capability 不满足时显示有界限的不支持界面，不隐藏或假装成功。
