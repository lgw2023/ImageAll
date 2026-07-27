# Cursor CLI 任务：library-slimming-s5

## 状态

- 任务 ID：`library-slimming-s5`
- 状态：Ready（待实施）
- 权威交接单：`docs/CURSOR-LIBRARY-SLIMMING-S5-HANDOFF.md`
- 上一批准基线：`3e44f622e203bc6e3a1da0b71925575384e09fc9`
- 开工 HEAD：`<LAUNCH_HEAD>`（文档 commit 后替换为 `git rev-parse HEAD`）

## 开工 HEAD

`<LAUNCH_HEAD>`

## 完整任务正文

按 `docs/CURSOR-LIBRARY-SLIMMING-S5-HANDOFF.md` 交付 S5：Photos PhotoKit 回收/恢复引导/永久删 + 对账；统一回收站 UI；不含 S6。

## 禁止事项

- 不把 Photos 像素写入 App quarantine / 不直写 `.photoslibrary`
- 不使用私有 undelete API
- 不改写已批准 migration V001–V020
- 不 push；不 amend；不改写历史
- 不读、不改、不删 `/Volumes/HDD2` 受保护真实数据
- 不进入 S6+ 范围
- 无用户确认不得销毁原图
- PhotoKit mutation 仅允许出现在瘦身 Photos mutation 适配器

## 停止位置

S5 实现 + 测试 + Debug build 通过并完成本地 implementation commit；不进入 S6。

## 结果（实施后补记）

（待填）
