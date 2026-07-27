# Cursor CLI 任务：library-slimming-s2

## 状态

- 任务 ID：`library-slimming-s2`
- 状态：Ready（待实施）
- 权威交接单：`docs/CURSOR-LIBRARY-SLIMMING-S2-HANDOFF.md`
- 上一批准基线：`a9cef7e41dfc33084afd58fa8d3cfe6729bca8dc`
- 开工 HEAD：`<LAUNCH_HEAD>`（本记录与交接单文档提交后的 `git rev-parse HEAD`）
- 交付 commit：（实施后补记）

## 开工 HEAD

文档交接提交后的 `git rev-parse HEAD`（本记录与交接单一并提交后即为该值）。

## 完整任务正文

按 `docs/CURSOR-LIBRARY-SLIMMING-S2-HANDOFF.md` 交付 S2：Feature Print 召回 + DINOv2 精排聚类服务；侧栏「图库瘦身」只读浏览簇；相同档优先；待分析显式标记；不删原图。

## 禁止事项

- 不删除/移动原图；不调用 PhotoKit mutation
- 不实现回收站 / quarantine
- 不 push；不改写已批准 migration（V001–V018）
- 不读 `/Volumes/HDD2` 受保护真实数据
- 不进入 S3+ 范围

## 停止位置

S2 实现 + 测试 + Debug build 通过并完成本地 implementation commit；不进入 S3。

## 结果（实施后补记）

（待填）
