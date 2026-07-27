# Cursor CLI 任务：library-slimming-s4

## 状态

- 任务 ID：`library-slimming-s4`
- 状态：Ready（待实施）
- 权威交接单：`docs/CURSOR-LIBRARY-SLIMMING-S4-HANDOFF.md`
- 上一批准基线：`95cd8cd898e03517d030588c627cbda79f265640`
- 开工 HEAD：`3513ef539c03072a838022b1984a1bb3a3a11b40`（文档提交后替换为精确值）

## 开工 HEAD

3513ef539c03072a838022b1984a1bb3a3a11b40

## 完整任务正文

按 `docs/CURSOR-LIBRARY-SLIMMING-S4-HANDOFF.md` 交付 S4：文件夹 quarantine 回收站 + 倒计时 + 恢复 + purge Job；不含 Photos 写入。

## 禁止事项

- 不实现 PhotoKit mutation / Photos quarantine 冒充
- 不改写已批准 migration V001–V018
- 不 push；不 amend；不改写历史
- 不读、不改、不删 `/Volumes/HDD2` 受保护真实数据
- 不进入 S5+ 范围
- 无用户确认不得销毁原图

## 停止位置

S4 实现 + 测试 + Debug build 通过并完成本地 implementation commit；不进入 S5。

## 结果（实施后补记）

（待补）
