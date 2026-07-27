# Cursor CLI 任务：library-slimming-s1

## 状态

- 任务 ID：`library-slimming-s1`
- 状态：Ready → 本会话直接实施（所有者要求：先提交 S0 文档，再开 S1）
- 权威交接单：`docs/CURSOR-LIBRARY-SLIMMING-S1-HANDOFF.md`
- 上一批准基线：`8b8eba0a1efbe41b235938cb8b37c10708bc3163`

## 开工 HEAD

文档交接提交后的 `git rev-parse HEAD`（本记录与交接单一并提交后即为该值）。

## 禁止事项

- 不删除/移动原图；不调用 PhotoKit mutation
- 不改 `LibraryWorkspace.swift` / `LibraryWorkspaceModelTests.swift` 既存未提交草稿
- 不 push；不改写已批准 migration
- 不读 `/Volumes/HDD2` 受保护真实数据

## 停止位置

S1 实现 + 测试 + Debug build 通过并完成本地 implementation commit；不进入 S2。

## 结果（实施后补记）

- 开工 HEAD：
- 交付 commit：
- 测试命令与退出码：
- 测试总数：
- Debug build：
- 工作区：
