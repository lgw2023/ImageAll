# ImageAll 建议阈值 ST4：人工确认的参考值与完成统计

> 状态：已完成并通过 Codex 独立复审
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

## 交付与复审证据

- 开工 HEAD：`5a3f727542e288253cf859e4d08aaf6dc9984e5b`
- 本任务开工留档：`5f60e657`
- 实现 commit：`18172b10ee6d087cb37ac8168c14d5caea267ce6`
- 实现归属：

  ```text
  Codex <codex@openai.com>
  feat(codex): complete suggestion threshold guidance
  Agent-Role: implementation
  ```

- Cursor CLI：未使用；无 session ID。
- migration：未新增、未改写；v014 / v015 保持原样。
- 受保护真实照片：未访问、未枚举、未写入。

### RED → GREEN

1. `SuggestionThresholdTests`
   - 先证明活动标签没有既有覆盖时无法出现在设置列表；
   - 再证明同标签同方法最近 20 个拒绝分数采用 nearest-rank P90，少于 5 个时
     不返回参考值，且质心 / AdamW / Feature Print 不混用。
2. `AppModelActivationCoordinatorTests`
   - 先证明设置模型缺少参考值投影；
   - 再证明展示参考值不会写库，只有调用“采用”才写目标标签与方法的覆盖。
3. `LibraryWorkspaceModelTests`
   - 先证明个人完成通知缺少高于阈值与实际写入的区分；
   - 再证明质心、AdamW 与 Feature Print 都展示真实候选数和高于阈值数。
4. `FullLibrarySuggestionsJobTests`
   - 先证明 Feature Print 没有按 `job_id` 读取完成 checkpoint 的投影；
   - 再证明完成状态与 `eligibleCount / suggestedCount / skippedCount` 一致。

### 验收命令与结果

```text
xctest -XCTest \
  ImageAllTests.SuggestionThresholdTests,\
  ImageAllTests.AppModelActivationCoordinatorTests,\
  ImageAllTests.FullLibrarySuggestionsJobTests,\
  ImageAllTests.TrainingWorkspaceSchemaTests,\
  ImageAllTests.LibraryWorkspaceModelTests \
  ImageAllTests.xctest
```

- 退出码：0
- 结果：247 tests，0 failures，0 unexpected。

```text
xctest ImageAllTests.xctest
```

- 退出码：1（仅仓库已用 `XCTExpectFailure` 标注的基线）
- 结果：1098 tests，11 failures，**0 unexpected**。
- expected-failure 仍集中在旧 migration DDL 不变式等已知清单，不属于 ST4
  产品或实现回归；正式 CI 前仍应按测试名、原因、环境、负责人和清理切片维护
  独立清单。

```text
xcodebuild build -quiet -project ImageAll.xcodeproj -scheme ImageAll \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath <TEMP_DERIVED_DATA> CODE_SIGNING_ALLOWED=NO
```

- 退出码：0；Debug build 通过。
- 仅有既存 LibRaw 构建目标版本 linker warning。

```text
git diff --check
```

- 退出码：0。

## Codex 复审结论

1. 参考值只读且按 `(tag_id, method)` 隔离；采用前不修改默认或覆盖。
2. Settings 列出全部活动标签，因此首次覆盖无需先由其它路径制造一条覆盖记录。
3. Review 概览异步加载参考值，避免 SwiftUI 重绘时同步执行参考 SQL。
4. 三轨完成通知都区分候选、高于阈值、实际写入和跳过；Feature Print 数据来自
   持久 job checkpoint。
5. 未发现阻塞 ST4 关闭的问题。ST4 在本文件的关闭文档提交处停止，不进入评测、
   公共模型替换或其它未批准能力。
