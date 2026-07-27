# 任务：mac-host-ios-companion-r0

## 状态

- 任务 ID：`mac-host-ios-companion-r0`
- 状态：In progress
- 权威决策：`docs/ADR-043-MAC-HOST-IOS-COMPANION.md`
- 上一批准基线：`aeb6d30b573b3d609cd9b43364e4b8d5174ea06d`
- 开工 HEAD：见实施后补记（ADR 文档提交后的 HEAD）
- 实施身份：临时授权期内由会话直接实施（至 2026-08-13）；实现提交使用 `Codex <codex@openai.com>` / `feat(codex):` / `Agent-Role: implementation`

## 范围

1. 落地 ADR-043（文档 commit，与实现分离）
2. `Packages/ImageAllRemoteProtocol`：capabilities / sources / assets / thumbnail query / tag batch DTO + round-trip 测试
3. Mac 薄层：`RemoteCatalogFacade` + 最小 HTTP Host + `network.server` entitlement
4. 在 `CompositionRoot` 挂载 Host（默认关；开发开关可开）；**不修改** `LibraryWorkspace.swift`

## 禁止事项

- 不改 `LibraryWorkspace.swift` / `LibraryWorkspaceModelTests.swift` 既存未提交草稿
- 不拆 `LibraryWorkspacePort`；不做工程大搬家；不建完整 iOS App（留给 R1）
- 不 push；不读 `/Volumes/HDD2` 受保护真实数据
- 不同步 SQLite；不做远程桌面

## 停止位置

R0：Protocol + Mac Host 可测可构建；停止于 R1（iOS 壳）边界。

## 结果（实施后补记）

（待补）
