# ImageAll 建议阈值 ST4：人工确认的参考值与完成统计

> 状态：实施中
> 日期：2026-07-23
> 权威规格：`docs/SUGGESTION-THRESHOLD-SPEC.md`
> 架构决策：`docs/ARCHITECTURE.md` ADR-039 / ADR-040
> 上一批准基线：训练工程 T4 复审留档
> `main@5a3f727542e288253cf859e4d08aaf6dc9984e5b`

## 开工门

- 训练工程 T2–T4 已完成并通过独立复审；当前跟踪工作区干净。
- T3/T4、阈值与训练关键套件重新执行时，除一个并行运行下的
  `LibraryWorkspaceModelTests` 用例失败外均通过；该用例隔离重跑通过，后续验收固定
  使用串行测试，避免把资源竞争误判为产品回归。
- ADR-040 的 ST1–ST3 已由 `73c872fbbd41c06b744519a7815ea1defe3f19e3`
  实现：v015、三轨生效门槛、刷新 pending、Settings/标签副入口和 Review 原始分数
  均在当前树中。
- Cursor CLI 未使用；依据 `AGENTS.md` 至 2026-08-13 的临时授权，由 Codex 直接
  按 TDD 实施。

## 产品契约

1. 参考建议按 `(tag_id, method)` 独立计算，禁止跨轨比较或混合分数。
2. 只使用已有人工拒绝事实与当时仍可追溯的该方法原始 prediction score；不读取
   原图，不新增图片、路径、bookmark 或像素审计数据。
3. 首版取最近 20 个可追溯拒绝分数的第 90 百分位（nearest-rank），至少 5 个样本
   才显示数值；UI 必须同时显示样本数与口径，样本不足时显示“暂无参考建议”。
4. 参考值始终只读。只有用户点“采用”才写入该标签、该方法覆盖；忽略或关闭不改库，
   重建/训练也不自动改阈值。
5. 三轨生成结束的用户可见反馈写明“高于阈值 N 条 / 候选 M 条”；若实际写入数受
   人工事实、并发或 Top 100 限制影响，同时诚实展示写入数。
6. Feature Print 的完成统计复用持久 job checkpoint；个人质心/AdamW 复用本次
   前台批次结果，不新增 migration。

## TDD 纵向切片

1. RED→GREEN：阈值仓储从同标签同方法的最近拒绝 prediction 生成稳定参考值；
   方法隔离、最小样本、nearest-rank 与非有限值 fail closed。
2. RED→GREEN：模型层加载参考值，用户采用后仅写目标覆盖；忽略不产生写入。
3. RED→GREEN：个人质心/AdamW 完成 notice 展示高于阈值数、候选数与实际写入数。
4. RED→GREEN：Feature Print 最新完成 checkpoint 投影并展示相同统计。
5. UI 结构验收：Settings/标签副入口可见参考说明与“采用”，没有自动应用行为。

## 验收矩阵

- `SuggestionThresholdTests`：方法隔离、最近样本、90 百分位、样本不足、采用/忽略。
- `LibraryWorkspaceModelTests`：三轨完成反馈统计与参考值采用。
- `FullLibrarySuggestionsJobTests`：Feature Print checkpoint 统计投影。
- 训练工程 T2–T4 与 Review 全并行关键回归。
- 串行完整 XCTest、Debug build、`git diff --check`。

## 禁止事项

- 不新增或改写 migration；尤其不改 v014 / v015。
- 不保存新的审核历史表，不把“参考建议”称为准确率或概率。
- 不自动采用参考值，不在模型训练/重建时改阈值。
- 不做准确率仪表盘、evaluation assignment、图表大屏或云端训练。
- 不访问、枚举或写入 `/Volumes/HDD2` 受保护真实照片路径。
- 不启动 production App 测试宿主。
- 不 push、不 amend、不 squash、不清理来源不明文件。

## 停止位置

完成 ST4 的参考建议 UI、人工采用和三轨生成完成统计后，创建独立 Codex 实现
commit；随后独立复审并以单独文档 commit 回填证据。ST4 复审结束即停止，不进入
评测、模型替换或其他未批准能力。
