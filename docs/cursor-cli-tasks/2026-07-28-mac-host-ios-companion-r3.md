# 任务：mac-host-ios-companion-r3

## 状态

- 任务 ID：`mac-host-ios-companion-r3`
- 状态：Delivered
- 权威决策：`docs/ADR-044-MAC-HOST-COMPANION-R3.md`
- 开工 HEAD：`e90a8c2e808e97fc14666af5880a26876251b024`
- 实施身份：临时授权期内直接实施；文档 `docs(codex):`；实现 `feat(codex):`

## 范围

按 ADR-044 一次落地：配对、TLS（指纹固定）、持久幂等、WebSocket、preview/inspector/selection/review/jobs 远程面、Mac 设置配对面板、Mobile 配对与事件驱动刷新。

## 禁止事项

- 不做自建 Relay / WebRTC / SQLite 同步
- 不改写 `LibraryWorkspaceModel` 主路径为网络入口
- 不 push；不读受保护真实照片
- 保留无关 `LibraryWorkspace*` / migration 未提交草稿

## 停止位置

R3 完成辅助闭环；停止于 R4 Relay。

## 结果（实施后补记）

- 开工 HEAD：`e90a8c2e808e97fc14666af5880a26876251b024`
- 交付 commit：待回填
- Package：Protocol **9** / Client **5** passed
- Xcode Remote 套件：`TEST SUCCEEDED`（Facade/HTTP/Pairing/Idempotency/Identity 全过）
- Mac Debug + iOS Simulator Debug：`BUILD SUCCEEDED`
- 未 push；无关草稿未纳入提交
