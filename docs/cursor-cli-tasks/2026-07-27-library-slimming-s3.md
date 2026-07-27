# Cursor CLI 任务：library-slimming-s3

## 状态

- 任务 ID：`library-slimming-s3`
- 状态：In progress
- 权威交接单：`docs/CURSOR-LIBRARY-SLIMMING-S3-HANDOFF.md`
- 上一批准基线：`d205f555c730103f206472856d3fe27d0c15099f`
- 开工 HEAD：`<LAUNCH_HEAD>`（文档提交后替换为精确值）
- 交付 commit：

## 开工 HEAD

文档提交后以 `git rev-parse HEAD` 为准。

## 完整任务正文

按 `docs/CURSOR-LIBRARY-SLIMMING-S3-HANDOFF.md` 交付 S3：种子图 / 标签范围两种入口；簇内多选对比 UX；仍不删原图。

## 禁止事项

- 不删除/移动原图；不调用 PhotoKit mutation
- 不实现回收站 / quarantine
- 不 push；不改写已批准 migration（V001–V018）
- 不读 `/Volumes/HDD2` 受保护真实数据
- 不进入 S4+ 范围

## 停止位置

S3 实现 + 测试 + Debug build 通过并完成本地 implementation commit；不进入 S4。

## 结果（实施后补记）

- 开工 HEAD：
- 交付 commit：
- 测试命令与退出码：
- 测试总数：
- Debug build：
- 工作区：
