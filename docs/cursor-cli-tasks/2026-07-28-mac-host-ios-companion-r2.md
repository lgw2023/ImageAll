# 任务：mac-host-ios-companion-r2

## 状态

- 任务 ID：`mac-host-ios-companion-r2`
- 状态：Delivered（等待复审；用户指示可不复审继续）
- 权威决策：`docs/ADR-043-MAC-HOST-IOS-COMPANION.md`（R2 = Bonjour 发现；TLS/配对/WebSocket/中继后置）
- 上一批准基线：R1 交付 `e7c9ec5df9563623239a0db07a1d596be8d45152`；开工 HEAD：`635e85bc3bf5d984df65ed6d1a2b9ff5e08120f8`
- 实施身份：临时授权期内由会话直接实施（至 2026-08-13）；文档 `docs(codex):` / 实现 `feat(codex):` / 对应 `Agent-Role`

## 范围

1. 协议：Bonjour service type + TXT 键（protocolVersion）
2. Mac Host：`NWListener` 在 Debug Host 启动时发布 Bonjour；Mac/iOS Info.plist 声明 `NSBonjourServices`
3. `ImageAllRemoteClient`：`RemoteHostBrowser` 浏览并 resolve 为 host:port
4. `ImageAllMobile`：连接页列出发现的 Host，点选填入；仍手动粘贴 access token（正式配对后置）

## 禁止事项

- 不做 TLS、正式配对/QR、WebSocket、异地中继
- 不改 `LibraryWorkspaceModel` 主交互；不为 Bonjour 大改 Mac UI
- 不 push；不读受保护真实照片路径

## 停止位置

R2：同局域网可发现 Mac Host 并连接（token 仍手动）；停止于 R3（配对/TLS/事件）边界。

## 结果（实施后补记）

- 开工 HEAD：`635e85bc3bf5d984df65ed6d1a2b9ff5e08120f8`
- 交付 commit：待实现提交后回填
- Package 测试：
  - `Packages/ImageAllRemoteProtocol` swift test → **7 passed**
  - `Packages/ImageAllRemoteClient` swift test → **5 passed**
- 定向 Xcode（Mac）：`RemoteCatalogFacadeTests` + `RemoteHTTPServerTests` → **13 passed**，`TEST SUCCEEDED`
- Debug build：
  - Mac `ImageAll` → `BUILD SUCCEEDED`（`.derivedData-remote-r2`）
  - iOS Simulator `ImageAllMobile` → `BUILD SUCCEEDED`（`.derivedData-mobile-r2`）
- 状态：Delivered；停止于 R3 边界
- 未做配对/TLS/WebSocket；未 push
- Bonjour type：`_imageall._tcp`
