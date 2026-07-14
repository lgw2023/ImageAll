# Cursor CLI 任务留档

本目录保存 Codex 向 Cursor CLI 下发的可审计任务。它记录“谁定义任务、谁实施、从哪一个基线开始、使用了什么模型、如何验证”，但不保存体积很大的完整 `stream-json` 输出。

## 一项任务一份记录

- 新阶段、新切片或新的独立交接单：新建 `YYYY-MM-DD-<task-id>.md`，并启动全新的 Cursor session；
- 同一交接单未通过验收的窄范围返修：追加在原文件中，并且只允许续接该任务原 session；
- 交接任务通过或关闭后：session 退役，后续任务不得恢复它。

## 记录时点

1. **调用前**：提交权威 handoff、完整 CLI 命令模板、完整任务正文、上一批准基线、禁止事项和停止位置。此时 `<LAUNCH_HEAD>` 表示“包含本记录的 Codex launch commit”；
2. **调用时**：先确认工作区干净，把 `<LAUNCH_HEAD>` 替换为 `git rev-parse HEAD` 的精确 SHA，再启动全新 session；
3. **Cursor 交付后**：Codex 独立复核 diff、测试、构建、作者归属和工作区，再把实际 SHA、模型、session ID、交付 commit 与评审结论追加到本记录，形成单独的 Codex 文档 commit。

这样避免任务记录对“包含自身的 commit SHA”产生循环引用，同时仍能还原实际调用。

## 提交归属

| 角色 | 允许内容 | Author | 主题前缀 | Trailer |
|---|---|---|---|---|
| Codex | 产品、架构、规格、handoff、任务留档与评审结论 | `Codex <codex@openai.com>` | `docs(codex):` | `Agent-Role: product-architecture` |
| Cursor | 当次授权的实现、测试和必要工程引用 | `Cursor Agent <cursoragent@cursor.com>` | `feat(cursor):` / `fix(cursor):` | `Agent-Role: implementation` |

单个 commit 不混合两种职责，不使用 `Co-authored-by` 模糊实际主作者。两种 identity 都只通过当次 `git -c user.name=... -c user.email=... commit` 设置。

## 最小字段

- 状态与任务 ID；
- 权威 handoff 路径；
- 上一批准基线和实际开工 HEAD；
- 完整 CLI 命令与任务正文；
- `system/init.model` 和 Cursor session ID；
- 实施 commit 与作者/trailer 证据；
- 测试总数、构建结果、运行证据；
- 禁止事项、停止位置、Codex 评审结论；
- 最终分支、工作区状态、是否 push。

不得记录 API key、token、照片内容、用户文件路径详情或其他凭据。受保护真实数据规则仍以 [`../LOCAL-TEST-DATA-SAFETY.md`](../LOCAL-TEST-DATA-SAFETY.md) 为准。
