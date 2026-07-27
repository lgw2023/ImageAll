# 任务：mac-host-ios-companion-r1

## 状态

- 任务 ID：`mac-host-ios-companion-r1`
- 状态：Delivered（等待复审）
- 权威决策：`docs/ADR-043-MAC-HOST-IOS-COMPANION.md`
- 上一批准基线：R0 交付证据 `703026c78664cc6e974f72e3831e7325a4390cbe`；开工 HEAD：`f9642cef36f1a963f078aa5fbea5eb94f857a676`
- 实施身份：临时授权期内由会话直接实施（至 2026-08-13）；文档提交使用 `Codex <codex@openai.com>` / `docs(codex):` / `Agent-Role: product-architecture`；实现提交使用 `Codex <codex@openai.com>` / `feat(codex):` / `Agent-Role: implementation`

## 范围

1. 为 R1「改标签」补齐最小 tags 列表：协议 DTO + Host `GET /v1/tags`（薄扩展，不拆 `LibraryWorkspacePort`）
2. `Packages/ImageAllRemoteClient`：HTTP Client（capabilities / sources / tags / assets / thumbnail / tag-batch）+ package 单测
3. 最小 iOS 壳 `ImageAllMobile`：连接设置（host/port/token）、来源列表、资产网格+缩略图、选标签后 accept/reject/clear
4. iOS `Info.plist` 声明局域网用途；明文 HTTP 仅开发期（ATS 例外限本地）

## 禁止事项

- 不改 `LibraryWorkspace.swift` / `LibraryWorkspaceModel` 主交互
- 不做 Bonjour / TLS / WebSocket / 异地中继（R2+）
- 不做工程大搬家到 `Apps/`
- 不 push；不读 `/Volumes/HDD2` 受保护真实数据
- 不同步 SQLite；不做远程桌面

## 停止位置

R1：模拟器/设备可连接本机 Debug Host，浏览网格并提交标签决定；停止于 R2 边界。

## 结果（实施后补记）

- 开工 HEAD：`f9642cef36f1a963f078aa5fbea5eb94f857a676`
- 交付 commit：`e7c9ec5df9563623239a0db07a1d596be8d45152`
- Package 测试：
  - `cd Packages/ImageAllRemoteProtocol && swift test` → **6 passed**
  - `cd Packages/ImageAllRemoteClient && swift test` → **4 passed**
- 定向 Xcode（Mac）：`RemoteCatalogFacadeTests` + `RemoteHTTPServerTests` → **12 passed**，`TEST SUCCEEDED`
- Debug build：
  - Mac `ImageAll` → `BUILD SUCCEEDED`（`.derivedData-remote-r1`）
  - iOS Simulator `ImageAllMobile` → `BUILD SUCCEEDED`（`.derivedData-mobile-r1`）
- 状态：Delivered（等待复审）；停止于 R2 边界
- 未做 Bonjour/TLS/WebSocket；未 push
- Host 启用：`defaults write com.gwlee.ImageAll imageall.remoteHost.enabled -bool YES`
- Token：`defaults read com.gwlee.ImageAll imageall.remoteHost.accessToken`
- Mobile 连接：模拟器可用 `127.0.0.1:8787` + 上述 token
