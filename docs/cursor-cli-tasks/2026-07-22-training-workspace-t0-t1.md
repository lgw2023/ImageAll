# 训练工程工作区 T0/T1

## 任务状态

- T0：进行中 → 文档提交后关闭
- T1：待执行（本记录授权范围内由实施方直接完成）

## 权威交接单 / 规格

- [`docs/TRAINING-WORKSPACE-SPEC.md`](../TRAINING-WORKSPACE-SPEC.md)
- [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) ADR-038 / ADR-039

## 上一批准基线

- `main@c10b022770c34f02c84b708fdb6c7b3e30f894d5`

## 开工 HEAD 确定规则

1. T0 文档提交后的 `git rev-parse HEAD` 为 T1 开工 HEAD。
2. 工作区 AdamW WIP 已 stash（`adamw-wip-before-training-workspace-t1`），未跟踪 AdamW 源码备份在 `.wip-adamw-backup/`；T0/T1 不得混入。

## 范围

### T0

- 批准 TW-P6（侧栏整页）、TW-P7（统一 Run 列表）
- 提交规格与 ARCHITECTURE ADR 指针

### T1

- migration `v014`：`training_run` + 个人多槽 schema
- 仓储：按 method 激活/替换预测，禁止激活时 `DELETE` 全表
- 读写契约与反例测试
- **不做**：Review 全并行 UI、训练工程大页、写 Run 到训练路径（T2+）

## 停止位置

T1 测试与 Debug build 通过并提交后停止；不进入 T2。

## 禁止事项

- 不 push、不 amend、不改写已批准 migration 历史
- 不触碰受保护真实照片路径
- 不与 AdamW WIP / derivedData 混提
