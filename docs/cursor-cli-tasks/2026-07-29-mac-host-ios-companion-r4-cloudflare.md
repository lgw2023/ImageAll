# Mac Host + iOS Companion R4A：Cloudflare 公网纵切片

## 状态

- 任务 ID：`mac-host-ios-companion-r4-cloudflare`
- 状态：Delivered at R4A boundary（公网配对、三页加载、WebSocket 与 Keychain 自动恢复已通过）
- 日期：2026-07-29
- 权威决策：
  - `docs/ADR-043-MAC-HOST-IOS-COMPANION.md`
  - `docs/ADR-044-MAC-HOST-COMPANION-R3.md`
  - `docs/ADR-047-MAC-HOST-CLOUDFLARE-PUBLIC-TUNNEL.md`
- 部署入口：`https://imageall.ultrahardcore.net`

## 所有者选择与停止位置

当前 Mac 与实体 iPhone 位于互相隔离的 Wi-Fi 子网，纯 HTTP 探针也不能互访。项目所有者明确
要求停止局域网产品路径，改用其自有域名和现有 `cloudflared` 常驻 Tunnel。

本轮只实现单一所有者、单一 Mac、单一自有 Tunnel 的最小公网纵切片。Mac 仍是唯一 catalog、
PhotoKit、文件、标签、审核和任务写权威；Mobile 不同步 SQLite，不进入
`LibraryWorkspaceModel`，不实现 WebRTC、远程桌面、多租户 Relay、后台唤醒或多 Host 路由。

R4A 接受 Cloudflare 作为 TLS 终止和应用层可见的信任方，不宣称 Relay 不可见内容。应用层
端到端加密如需实现，必须另开 R4B ADR。

## 工作区与 Git 边界

- 实现只在隔离 worktree `/Volumes/SSD1/ImageAll-R3-Polish` 和分支
  `lgw/imageall-mobile-r3-polish` 进行；
- 主工作区 `/Volumes/SSD1/ImageAll` 的另一会话草稿未被修改、暂存、stash、reset 或 clean；
- R4A 架构决策已独立提交：`1e4821eb docs: decide Cloudflare public Companion tunnel`；
- R4A 实现与测试已独立提交：`6ffc89ac feat: add public Companion tunnel endpoint`；
- 默认不 push；Tunnel UUID、credentials 路径、配对令牌、bearer 和完整证书指纹不写入仓库证据。

## 实现

### Protocol / Client

- `RemotePairingOffer` 和 `RemoteSessionTokens` 增加向后兼容的可选 `publicBaseURL`；
- 公网 URL 仅接受专用根路径 HTTPS 域名，拒绝 userinfo、query、fragment、IP literal、路径和
  非标准端口，并统一为小写 Host、标准 443；
- Client 增加系统信任的公网 HTTPS endpoint；
- pairing 与 refresh 会把 Host ID、TLS 模式、证书指纹和公网 endpoint 绑定，任何漂移均要求
  重新扫码；
- 旧 R3 payload 缺少 `publicBaseURL` 时仍可解码并继续局域网路径。

### Mac Host

- Host 可从设置或 `IMAGEALL_REMOTE_PUBLIC_BASE_URL` 读取公网 Base URL，并写入短时 QR、
  pairing complete 和 refresh DTO；
- 设置页把开关改为“启用移动 Host”，增加公网 URL 保存、当前生效入口和公网模式说明；
- 所有 HTTP 响应增加 `Cache-Control: no-store` 与 `Pragma: no-cache`；
- HTTP/WebSocket 鉴权、短时单次配对令牌、access/refresh 轮换、撤销和持久幂等沿用 R3。

### iOS Mobile

- 扫到含公网 URL 的 QR 后不再依赖 Bonjour 或局域网地址，直接使用系统信任的公开 HTTPS；
- 公网 HTTP 与 WebSocket 均使用 `https/wss`，本地 R3 路径继续固定 Mac 自签证书指纹；
- 公网 endpoint 与 refresh token 分别持久化到偏好和 Keychain，重启后可恢复会话；
- 连接页明确区分“公网 Host”和局域网 Host，连接状态显示“公网 TLS”。

## Cloudflare 部署

只在现有 `~/.cloudflared/config.yml` 的 catch-all 之前新增以下非秘密规则，未改变其他 hostname：

```yaml
- hostname: imageall.ultrahardcore.net
  service: https://127.0.0.1:8787
  originRequest:
    noTLSVerify: true
```

`noTLSVerify` 只用于同一台 Mac 的 loopback 自签 origin；iPhone 到 Cloudflare 边缘仍使用公开证书
和系统 TLS。配置通过 `cloudflared tunnel ingress validate`。DNS CNAME 已由
`cloudflared tunnel route dns` 创建；既有 `com.cloudflare.cloudflared` LaunchAgent 已受控重启
并保持运行。Mac Application Firewall 保持原“阻止所有非必要传入”与隐身模式，因为 Tunnel
只建立出站连接。

公网未授权探针最终得到 Host `401 Unauthorized`，同时观察到：

- Cloudflare 公开证书握手成功；
- origin 命中新增 ingress，而不是 catch-all；
- `Cache-Control: no-store`、`Pragma: no-cache` 穿过 Cloudflare 保留；
- Cloudflare 返回动态非缓存响应。

本机 DNS 曾短暂命中新增记录前的负缓存；公共解析器已返回 Cloudflare 地址。验收探针使用同一
公网 hostname、SNI 和公开证书，只在本机临时固定已解析的 Cloudflare edge IP 绕过该负缓存。

## 自动化与构建证据

所有自动化与 Host smoke 使用空的隔离开发根：

`~/Library/Containers/com.gwlee.ImageAll/Data/Library/Application Support/ImageAll-R3-IsolatedHost-20260729`

进程文件描述符检查只命中该隔离 catalog，没有 `/Volumes/HDD2` 或生产 ImageAll catalog 句柄。

| 验证 | 结果 |
|---|---|
| `Packages/ImageAllRemoteProtocol`：`swift test -q` | 11 tests，0 failures |
| `Packages/ImageAllRemoteClient`：`swift test -q` | 35 tests，0 failures |
| Mac Remote `build-for-testing` | `TEST BUILD SUCCEEDED` |
| 裸 bundle 定向 `RemoteHTTPServerTests` + `RemotePairingStoreTests` | 18 tests，0 failures |
| Mac Debug，未签名 macOS | `BUILD SUCCEEDED` |
| Mac Debug，Apple Development 签名 macOS | `BUILD SUCCEEDED` |
| Mobile Debug，generic iOS Simulator | `BUILD SUCCEEDED` |
| Mobile Debug，Apple Development 签名 generic iOS Device | `BUILD SUCCEEDED` |
| `cloudflared tunnel ingress validate` | `OK` |
| 公网无 bearer capabilities 探针 | `401` + `no-store` |
| 公网 `/v1/events/websocket` Upgrade 探针 | `101 Switching Protocols`；连接保持至 6 秒探针主动结束 |
| `git diff --check` | 通过 |

没有运行会启动生产 `ImageAll.app` test host 的聚合 `xcodebuild test`。Remote 定向测试采用
`build-for-testing` 后补测试 bundle rpath、临时 ad-hoc 重签并由裸 `xctest` 执行，避免在测试
方法前初始化生产 Photos store。

最终复跑的可复现命令：

```bash
(cd Packages/ImageAllRemoteProtocol && swift test -q)
(cd Packages/ImageAllRemoteClient && swift test -q)
xcrun xctest -XCTest RemoteHTTPServerTests,RemotePairingStoreTests \
  /Volumes/SSD1/.codex-build/ImageAll-R4A-Tests/Build/Products/Debug/ImageAll.app/Contents/PlugIns/ImageAllTests.xctest
xcodebuild -project ImageAll.xcodeproj -scheme ImageAll -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ImageAllMobile.xcodeproj -scheme ImageAllMobile -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ImageAllMobile.xcodeproj -scheme ImageAllMobile -configuration Debug \
  -destination 'generic/platform=iOS' build
plutil -lint ImageAllMobile/Info.plist
git diff --check
```

以上命令在隔离 worktree 执行，构建时实际分别指定了
`/Volumes/SSD1/.codex-build/ImageAll-R4A-Final-*` 外部 `derivedDataPath`；三项 build 均
exit 0，两个 package test 和裸 `xctest` 均 exit 0。

## 实体 iPhone 证据

- 设备：iPhone 16 Pro Max，iOS 26.5.2；
- 最新签名 ImageAll Mobile 已经由数据线安装并启动；
- 实体相机扫描包含 `https://imageall.ultrahardcore.net` 的短时二维码；
- 配对成功，Mobile 显示“已连接 1.0 (1) · 公网 TLS”并进入“图库 / 审核 / 任务”Tab；
- 当前隔离 catalog 没有来源和资产，因此图库正确显示“没有可浏览的项目”；这不是网络失败；
- 审核页正确显示“没有可审核标签”，任务页正确显示“当前没有任务”，均无连接错误；
- 最终设备包覆盖安装并重新启动后，未生成新二维码、未重新扫码；Mobile 自动用 Keychain
  refresh 返回“公网 TLS”会话，项目所有者已在实体 iPhone 上确认；
- Host 配对持久化状态的最新 `lastSeenAtMs` 在最终 App 启动后一秒更新，与该次免扫码 refresh
  一致；证据只记录时间，不记录 device ID 或 refresh token；
- 另以 Host 调试 bearer 经公网域名发起 WebSocket Upgrade，Cloudflare 到 Host 返回
  `101 Switching Protocols`，长连接保持到 6 秒探针主动结束。

真机截图和仓库证据不记录配对令牌、access/refresh bearer、完整 Host ID 或完整证书指纹。

## 已完成门与停止位置

1. 覆盖安装后不重新扫码，Keychain refresh 自动恢复“公网 TLS”会话：通过；
2. 图库、审核、任务页可以打开，空状态正确且无连接错误：通过；
3. 公网 WebSocket Upgrade 与长连接建立：通过；
4. 隔离 catalog 没有媒体，因此本轮没有在实体 iPhone 上打开具体图片预览，也没有制造
   review/job 业务事件；相关页面和协议实现已构建通过，但此项不冒充真机内容 smoke；
5. 本轮停止于单所有者、单 Mac、单自有 Cloudflare Tunnel 的 R4A 边界，不进入 R4B
   应用层端到端加密、多租户 Relay、推送唤醒或多 Host 路由。

## Codex 复审材料

当前 `AGENTS.md` 已统一 Codex / Cursor 职责；仓库当前树不再包含旧的
`.cursor/rules/codex-review-handoff.mdc`。本节仍按其历史交付字段提供等价复审材料，但旧规则
要求的 Cursor session ID、Composer 模型门和 Cursor 作者身份不适用于本轮 Codex 实施。

### 基线、范围与 Git 边界

- 开工实现基线：`34a4469c fix: improve Mobile pairing recovery guidance`；
- 架构决策提交：`1e4821eb docs: decide Cloudflare public Companion tunnel`；
- 实现交付提交：`6ffc89ac feat: add public Companion tunnel endpoint`；
- 分支 / worktree：`lgw/imageall-mobile-r3-polish` /
  `/Volumes/SSD1/ImageAll-R3-Polish`；
- 范围：公开 HTTPS endpoint、pairing/refresh endpoint 绑定、Mac 设置、Mobile 公网
  HTTP/WebSocket、自动恢复、Cloudflare ingress 与真机 smoke；
- 未做：同步 SQLite、`LibraryWorkspaceModel` 网络入口、远程桌面、WebRTC、应用层 E2E、
  多租户 Relay、后台唤醒、多 Host 路由；
- 未 push；主工作区和另一会话草稿未修改、stash、reset 或 clean。

实现提交归属：

```text
Codex <codex@openai.com>
feat: add public Companion tunnel endpoint
Agent-Role: implementation
```

### 变更职责

- `Packages/ImageAllRemoteProtocol`：公网 endpoint 严格规范化及 pairing/session DTO；
- `Packages/ImageAllRemoteClient`：公网 Client endpoint、payload 校验和会话身份绑定；
- `ImageAll/Infrastructure/Remote`：Host 公网上下文、DTO 回显与响应 `no-store`；
- `ImageAll/App/RemoteHostSettingsView.swift`：移动 Host 与公网入口设置；
- `ImageAllMobile/App`：扫码公网连接、系统 TLS、WebSocket、Keychain 自动恢复和 UI 状态；
- `ImageAllTests/Remote` 与两个 package tests：主路径、失败路径和向后兼容回归；
- `docs/ADR-047-MAC-HOST-CLOUDFLARE-PUBLIC-TUNNEL.md`：R4A 信任边界和验收门；
- 本任务留档：当前文件；R3 网络结论回写
  `docs/cursor-cli-tasks/2026-07-29-mac-host-ios-companion-r3-polish.md`。

### 请求重点审查

1. `RemotePublicEndpoint` 是否把公网系统信任路径限制在无歧义的专用 HTTPS 根域名；
2. pairing 与 refresh 是否在公网 endpoint 漂移时 fail closed，且旧 R3 payload 仍兼容；
3. Mobile 公网 HTTP/WebSocket 是否完全绕开自签指纹固定，而局域网 R3 路径仍保持固定；
4. 所有 Host HTTP 响应是否统一 `no-store`，Cloudflare ingress 是否仅影响新增 hostname；
5. 自动恢复是否只用 Keychain refresh，且不把 bearer、Tunnel secret 或真实照片写入证据。

**结论：** 本轮停止于 R4A 边界，等待复审；不顺手进入 R4B。

## 回滚

1. 从 `~/.cloudflared/config.yml` 删除 `imageall.ultrahardcore.net` ingress，并重启既有
   `com.cloudflare.cloudflared` LaunchAgent；
2. 删除该 hostname 的 Tunnel DNS route；
3. 在 Mac 设置清空公网入口并撤销已配对设备；
4. 不需要迁移或回滚 catalog、照片来源或 SQLite。
