# ADR-047：Mac Host Companion R4A — 自有域名 Cloudflare 公网 Tunnel

> 状态：已决定（2026-07-29，项目所有者明确要求停止局域网方案，改用其自有域名与现有
> `cloudflared` Tunnel）
> 相关：`docs/ADR-043-MAC-HOST-IOS-COMPANION.md`、
> `docs/ADR-044-MAC-HOST-COMPANION-R3.md`
> 当前部署：`https://imageall.ultrahardcore.net`

## 背景

R3 已完成局域网 Host、配对、自签 TLS 指纹固定、会话、WebSocket 与 Mobile 辅助面。实体设备
验证发现当前 Mac 与 iPhone 被网络分配到互相隔离的子网，简单 HTTP 探针也不能互访。项目所有者
已有自有域名和常驻的 locally-managed Cloudflare Tunnel，并明确选择公网路径继续开发。

普通 Cloudflare HTTP Tunnel 会在 Cloudflare 边缘终止公开 HTTPS，再把请求经 Mac 主动建立的
出站 Tunnel 转发到本机 origin。它不能透明保留 R3 的“iPhone 直接固定 Mac 自签证书”语义；
Cloudflare 的 TCP published application 又要求移动端运行 `cloudflared access tcp`，不适合作为
原生 iOS 产品依赖。

## 决策

### 1. 产品与权威边界不变

- ImageAll Mac 仍是唯一 GRDB、PhotoKit、文件来源、Job、标签和审核写权威；
- ImageAll Mobile 仍只消费 DTO、发送已鉴权命令，不保存或同步 SQLite；
- 网络入口仍是 `RemoteCatalogFacade` / `RemoteHTTPServer`，不经过
  `LibraryWorkspaceModel`；
- 不使用远程桌面、WebRTC 或客户端 `cloudflared`。

### 2. R4A 公网传输

- 使用专用域名 `https://imageall.ultrahardcore.net`；
- `cloudflared` 继续作为 Mac 上的常驻出站连接，不开放路由器端口，也不要求降低 Mac
  Application Firewall；
- Tunnel origin 指向 `https://127.0.0.1:8787`。现有 Host 继续使用 R3 自签 TLS；
  `cloudflared` 仅对该 loopback origin 使用 `noTLSVerify`；
- Cloudflare 边缘到 iPhone 使用公开证书和系统 TLS 信任；
- Host 设置中的可选公网 Base URL 会进入短时二维码和会话 DTO。Mobile 扫码后优先使用该公网
  URL；没有公网 URL 时继续使用 R3 Bonjour / 手动局域网地址和证书指纹固定；
- 公网 URL 必须是根路径 `https` URL，禁止 userinfo、query、fragment、非 443 显式端口和
  IP literal，避免二维码把 Mobile 引向弱化或含歧义的 endpoint；
- Mobile 必须把会话响应中的 Host ID、公网 URL、TLS 模式与扫码预期绑定。重启后的 refresh
  继续使用已配对并持久化的公网 URL。

### 3. 安全边界

- 二维码仍不得包含长期 access / refresh bearer，只包含短时、单次配对令牌；
- 除配对完成和 refresh 外，所有 HTTP / WebSocket 路由继续要求 Host bearer；
- Host 所有 HTTP 响应增加 `Cache-Control: no-store`，防止 Cloudflare 或其他中间层缓存
  capabilities、DTO、缩略图和预览；
- Host 默认启用，但只有用户开始约五分钟配对会话时才接受新设备；设置开关关闭后当前进程
  立即停止监听，再次打开则立即恢复，无需重启 App；
- 设备撤销、短期 access token、可轮换 refresh token、持久幂等与 WebSocket 鉴权沿用 R3；
- Tunnel 配置和仓库证据不得记录 Tunnel UUID、credentials 文件内容、pairing token、bearer
  或完整证书指纹。

### 4. 明确的信任取舍

R4A 是项目所有者自用/开发优先的公网纵向切片，**Cloudflare 是受信任的 TLS 终止方**。因此
Cloudflare 边缘理论上可见应用层请求、令牌和返回内容；这不是应用层端到端加密 Relay。

若产品以后要求 Relay 运营方也不能读取内容，必须另开 R4B ADR，引入设备公钥绑定的应用层
端到端加密、重放保护、密钥轮换与多 Host 路由。不得把 R4A 描述成已满足该目标。

### 5. Cloudflare Access 与缓存

R4A 不启用要求浏览器登录或客户端 `cloudflared` 的 Access 策略，避免破坏原生 URLSession /
WebSocket。公网 API 的第一道身份门仍是 ImageAll 配对会话；Cloudflare WAF、速率限制和
Access service token 可在不改变原生协议的后续加固切片评估。

所有 API 和图片响应都必须 `no-store`。不得为缩略图或预览开启 CDN Cache Rule。

## 验收门

1. Protocol / Client package 测试覆盖公网 URL round-trip、严格校验、会话 endpoint 绑定和
   缺字段兼容；
2. Mac 定向 Remote 测试覆盖配对 offer / refresh 回显公网 URL与 `no-store` 响应；
3. Mac 与 iOS Debug 构建通过；
4. 防火墙保持原策略时，公网域名未授权请求得到 Host `401`，没有活动配对时得到稳定失败；
5. 实体 iPhone 不依赖与 Mac 同一 Wi-Fi，可扫码完成配对并通过公开 HTTPS：
   capabilities、图库/缩略图、preview、review、jobs 与 WebSocket；
6. Mobile 重启后用 Keychain refresh 恢复会话；Mac 撤销设备后旧 refresh 失败；
7. 证据只记录域名、聚合结果和脱敏 Host ID，不记录令牌、完整指纹或照片内容。
8. 新安装启动后 Host 默认运行；设置开关可以在当前 App 进程内立即停止并再次启动。保存公网
   Base URL 后 Host 立即重载，后续新二维码包含生效后的公网入口，不要求重启 App。

## 停止位置

本切片停止于单一所有者、单一 Mac、单一自有 Cloudflare Tunnel 的可运行公网 Companion。
不顺手实现多租户 Relay、应用层 E2E、Cloudflare Access 登录、推送唤醒、后台常驻或多 Host
路由。

## 回滚

- 从 `cloudflared` ingress 删除 `imageall.ultrahardcore.net` 并移除对应 DNS route；
- 清空 Mac Host 公网 Base URL；
- Mobile 已配对设备可撤销并重新走 R3 局域网二维码；
- 不修改或迁移 catalog、照片来源和业务数据库。
