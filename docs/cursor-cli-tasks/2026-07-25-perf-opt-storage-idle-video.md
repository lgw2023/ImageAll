# Cursor CLI 任务：性能优化（存储迁移进度 / 非图片不入库 / 空闲预热）

- **任务 ID：** `perf-opt-storage-idle-video`
- **状态：** 产品契约已锁定；切片 A 可在交互会话实施，B/C 待后续独立 session
- **权威交接单：** [`docs/PERF-OPT-STORAGE-IDLE-VIDEO-HANDOFF.md`](../PERF-OPT-STORAGE-IDLE-VIDEO-HANDOFF.md)
- **上一批准基线：** `main@f00cf256`（handoff 撰写时）；正式 CLI 开工以含本文档的 Codex commit 为准

## 锁定决策（不得改写）

1. 整包应用存储迁移 + 进度 UI（增强现状，非仅派生缓存）
2. 视频/非图片不入库；已入库视频清除（含标签决定）
3. 空闲预热默认 ON，阈值 180s

## 切片顺序与停止

| 切片 | 内容 | 停止 |
|---|---|---|
| A | 枚举跳过非图片 + 清除已入库视频 | A 测通后停止 |
| B | 空闲 3 分钟预热默认开 | B 测通后停止 |
| C | 整包迁移任务与进度 | C 测通后关闭本单 |

## 禁止事项

- 不访问 `/Volumes/HDD2`、不遍历 `.photoslibrary`、不读写提交 `user/`
- 不 push、不 amend、不改写历史
- 不把文档与实现混进同一 commit

## CLI 模板（正式下发时替换 `<LAUNCH_HEAD>`）

```text
agent -p --model composer-2.5-fast --force --sandbox disabled --trust \
  --output-format stream-json --workspace /Volumes/SSD1/ImageAll <任务说明>
```
