# 任务：mac-host-ios-companion-r3

## 状态

- 任务 ID：`mac-host-ios-companion-r3`
- 状态：In progress
- 权威决策：`docs/ADR-044-MAC-HOST-COMPANION-R3.md`（补充 `docs/ADR-043-MAC-HOST-IOS-COMPANION.md`）
- 开工 HEAD：`9a140a1a4a3f9331a588b86bd72000cb4c1c0ee0`
- 实施身份：临时授权期内直接实施；文档 `docs(codex):`；实现 `feat(codex):`

## 范围

按 ADR-044 一次落地：配对、TLS（指纹固定）、持久幂等、WebSocket、preview/inspector/selection/review/jobs 远程面、Mac 设置配对面板、Mobile 配对与事件驱动刷新。

## 禁止事项

- 不做自建 Relay / WebRTC / SQLite 同步
- 不改写 `LibraryWorkspaceModel` 主路径为网络入口
- 不 push；不读受保护真实照片
- 保留无关 `LibraryWorkspace*` 未提交草稿

## 停止位置

R3 完成辅助闭环；停止于 R4 Relay。

## 结果（实施后补记）

- 待填
