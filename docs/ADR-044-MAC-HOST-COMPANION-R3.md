# ADR-044：Mac Host Companion R3 — 配对、TLS、WebSocket 与完整远程面

> 状态：已决定（2026-07-28，所有者要求按完整架构继续，不做半成品）  
> 相关：`docs/ADR-043-MAC-HOST-IOS-COMPANION.md`、`user/Mac Host  原生 iOS Companion.md`  
> 角色边界：架构决策与实现分 commit

## 决策

### 1. R3 一次落地的闭环（不做“只配对不 TLS”）

| 能力 | 要求 |
|---|---|
| **配对** | Mac 发起短时 pairing session（二维码/口令载荷）；手机提交设备名+设备公钥；Mac 持久化已授权设备；可撤销 |
| **TLS** | Host 使用自签身份（Keychain `SecIdentity`）提供 HTTPS；配对载荷带证书指纹；Client 固定指纹校验 |
| **会话** | 配对后发短期 `accessToken` + 可撤销 `refreshToken`；请求 `Authorization: Bearer` |
| **持久幂等** | `operationID` 落盘（Application Support）；跨重启重放同 mutation 返回原响应，冲突返回 409 |
| **WebSocket** | `GET /v1/events/websocket` 升级；推送目录/标签/任务/审核变更与 ping |
| **远程 API 面** | 在 R1 基础上补齐：asset detail、preview、tag selection aggregate、review queue/decisions、jobs 列表与有限动作 |

### 2. 明确不做（仍属后续）

- 自建公网 Relay / WebRTC
- 拆分重构整个 `LibraryWorkspacePort`
- 同步 SQLite 到手机
- 把 `LibraryWorkspaceModel` 变成网络入口

异地连通继续依赖用户侧 VPN/Tailscale 到达 Mac；产品中继另开 ADR。

### 3. 安全与信任

- 二维码**不得**含长期 bearer；只含 `hostID`、端口提示、`pairingToken`、证书指纹、过期时间、协议版本
- pairingToken 短有效（默认 5 分钟）、单次或有限次使用
- Debug 可保留紧急静态 token（defaults），正式会话以配对设备为准
- Host 默认仍关闭；配对/TLS/持久幂等齐备后，**允许**未来 Release 编译在显式用户开关下启用（本切片仍默认关；Release 不再无条件硬编码 `false`，改为与 Debug 相同的用户开关，但必须已有 Host TLS 身份）

### 4. Mac UI

允许 **Debug/设置面板** 展示：Host 开关状态、证书指纹、配对二维码/口令、已配对设备与撤销。不改写图库主交互。

### 5. 停止位置

R3 完成：同局域网可配对 → TLS 连接 → 浏览/标签/预览/审核/任务 → WebSocket 收到变更事件。  
停止于 Relay / 异地产品中继。

## 后果

- ADR-043 切片表中 **R3+** 拆为本 ADR 的 R3；Relay 记为 R4。
- 测试须覆盖：配对成功/过期/撤销、TLS 指纹不匹配拒绝、WS 握手、持久幂等跨“存储”、新 API 映射与鉴权失败。
