# Cursor CLI 任务：library-slimming-s6

## 状态

- 任务 ID：`library-slimming-s6`
- 状态：In Progress
- 权威交接单：`docs/CURSOR-LIBRARY-SLIMMING-S6-HANDOFF.md`
- 上一批准基线：`1d97535158be1ae910715a110fe713403dd72a1f`
- 开工 HEAD：`<LAUNCH_HEAD>`（本文档提交后替换为 `git rev-parse HEAD`）

## 开工 HEAD

`<LAUNCH_HEAD>`

## 完整任务正文

按 `docs/CURSOR-LIBRARY-SLIMMING-S6-HANDOFF.md` 交付 S6：可配置相似度阈值 + 大库按拍摄日分桶；相同档仍全局；种子模式不分桶；不引入簇结果持久化 migration；不扩展销毁路径。

## 禁止事项

- 不新增 `similarity_cluster_run` 持久化
- 不改写已批准 migration V001–V021
- 不 push；不 amend；不改写历史
- 不读、不改、不删 `/Volumes/HDD2` 受保护真实数据
- 不扩展 PhotoKit mutation / 新销毁 API
- 无用户确认不得销毁原图

## 停止位置

S6 实现 + 测试 + Debug build 通过并完成本地 implementation commit；不进入簇持久化或其他新阶段。

## 结果（实施后补记）

（待补）
