# 任务：mac-host-ios-companion-r2

## 状态

- 任务 ID：`mac-host-ios-companion-r2`
- 状态：In progress
- 权威决策：`docs/ADR-043-MAC-HOST-IOS-COMPANION.md`（R2 = Bonjour 发现；TLS/配对/WebSocket/中继后置）
- 上一批准基线：R1 交付 `e7c9ec5df9563623239a0db07a1d596be8d45152`；开工 HEAD：`452cc21e6f007117105509514646b8ef914e15cb`
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

- 开工 HEAD：待填
- 交付 commit：待填
- 测试 / 构建证据：待填
