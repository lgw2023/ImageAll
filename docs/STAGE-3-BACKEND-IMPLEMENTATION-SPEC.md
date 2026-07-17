# ImageAll 阶段 3 后端原型实施规格

> 状态：Backend prototype implemented
>
> 日期：2026-07-16
>
> 开工基线：`main@ccf17d841967d2d6f2b88763d341e7884c76f2fb`
>
> 交付基线：`main@45501b6a88422edf6ede900cb8982fc4ae268eea`
>
> 范围：只实现文件夹资产的个性化建议后端；不新增 Review、Inspector 或其他 SwiftUI

## 1. 决策与顺序

阶段 3 的非 UI 后端原型先于阶段 2 PhotoKit 接入实施。原因是自定义标签学习是
ImageAll 的核心差异化能力，而文件夹来源已经能完成连接、只读扫描、浏览和人工正负
标注，可以直接验证该闭环。此顺序不取消 PhotoKit；后续 Photos 资产仍通过相同的
Feature/Suggestion Application Ports 接入。

本轮固定为三个独立纵切片：

1. **Slice G — 个性化持久化**：新增 v004 与最小 repository；
2. **Slice H — Feature Print**：从一个已入库、可用的文件夹资产生成或读取版本化特征；
3. **Slice I — 有界建议评分**：发布每标签样本 revision，并对显式候选集写入建议。

每个切片独立测试、构建和本地提交。实现 commit 与文档 commit 分离，不 push。

## 2. 不变量

- 原图只读；不得删除、移动、重命名、覆盖或写入 sidecar、扩展属性和元数据；
- 自动化测试不得访问 `/Volumes/HDD2`，不得遍历 `.photoslibrary`；
- 人工 `accepted` / `rejected` 是事实，Feature、模型 revision 和 prediction 均为可重建派生数据；
- prediction 不能覆盖、替代或修改 `asset_tag_decision`；
- 归档 Tag 不发布新模型或建议；
- 分数是排序 margin，不是概率，不在本轮冻结面向用户的强度文案或阈值；
- 不做“全库 × 全部标签”的无界工作；Slice I 只接受显式、去重后的候选 Asset ID，
  首版上限 500；
- v001～v003 不修改，只追加 v004；不新增 entitlement、privacy manifest 或依赖。

## 3. Slice G：v004 与持久化边界

### 3.1 表

v004 新增五张 `STRICT` 表：

| 表 | 责任 |
|---|---|
| `feature` | 版本化 Feature Print 元数据与可重建缓存 key |
| `tag_model_revision` | 每标签不可变评分策略 revision |
| `tag_model_sample` | revision 使用的正负代表样本与稳定顺序 |
| `tag_model` | 每标签当前 revision 指针 |
| `prediction` | 资产在某模型 revision 下的可重建建议 |

最小约束：

- Feature identity 为 `asset + provider + request revision + preprocessing revision + content revision`；
- Feature 只允许 `vision-feature-print`、`float32`、正 element count/byte count、32-byte SHA-256；
- model revision 必须同时包含正例和反例，样本数、邻居数与预算为正数，邻居数不大于两类样本数；
- sample 只能引用该模型声明的 Feature provider/revision/preprocessing 与同 content revision 的 Feature；
- 同一 revision 的同一 Asset 只能出现一次；每个 role 的 rank 唯一且从零开始由 repository 校验；
- `tag_model.current_revision` 必须引用同 Tag 的已存在 revision；
- prediction 必须引用当前或历史 model revision，`score` 必须有限，状态首版仅为 `pendingReview`；
- 删除 Asset 级联删除 Feature/Sample/Prediction；Tag 仍以归档为产品动作，不提供删除入口。

### 3.2 最小 repository

Slice G 只交付：

- 注册 Feature 元数据；
- 原子发布 model revision、样本和 current pointer；
- 原子替换一个 Tag/revision/候选集合的 prediction；
- 查询当前、未被人工决定遮蔽的 pending prediction。

repository 必须在事务内重新检查 Tag active、Asset/content revision、Feature identity、人工决定
和 current revision。失败时不得留下半个模型或部分 prediction。

## 4. Slice H：Vision Feature Print

### 4.1 固定版本

- provider：`vision-feature-print`；
- Vision request revision：`2`；
- preprocessing revision：`1`；
- crop/scale：`scaleFill`；
- element type：只接受 Vision 返回的 `float32`；
- 缓存根：`Caches/ImageAll/Features/v1`，缓存 key 只能是应用生成的相对路径。

Feature 文件只保存 Vision observation 的原始 float32 data；数据库保存 element count、byte count
和 SHA-256。读取命中必须同时校验路径形状、普通文件、长度和 hash；失败视为可重建 miss。

### 4.2 单资产 Application Port

公开行为是 `loadOrGenerate(assetID)`：

1. 当前 identity 命中且文件校验通过时返回缓存；
2. 否则只读打开来源文件，复用现有 bookmark scope 与 no-follow 读取边界；
3. 校验入库 fingerprint、解码单张批准静态格式、生成 Feature Print；
4. 再次校验来源未变化后，先原子发布缓存文件，再注册 metadata；
5. 任何失败都不修改来源；数据库不得指向不存在或未校验的半文件。

本切片不接后台批处理、UI、模型评分或 Photos 资产。

## 5. Slice I：模型 revision 与有界评分

### 5.1 原型默认值

这些值仅为可替换的原型策略，不是面向用户的产品承诺：

- 最少正例 2、反例 2；
- 每类代表样本最多 12；
- 每类取最近最多 3 个样本的算术平均距离；
- `score = negativeMeanDistance - positiveMeanDistance`；值越大越接近正例；
- 首版写入条件为 `score > 0`。

2026-07-17 三个真实标签校准后，`2 + 2` 继续作为允许生成建议的硬门，概览另以非阻塞文案建议
正反样本各至少 4 张并覆盖不同内容。`score > 0` 继续只作为原型候选写入条件；不同标签的分数区间
不可直接比较，因此 UI 仍不显示 score、百分比或固定高/中/低分档。运行证据与混合质量结论见
[`STAGE-3-REVIEW-QUEUE-IMPLEMENTATION-SPEC.md`](./STAGE-3-REVIEW-QUEUE-IMPLEMENTATION-SPEC.md) 第 8.1 节。

当前产品验收只要求该本地轻量基线能够完成可恢复、可审核且不覆盖人工事实的建议闭环，不要求它对
现有相册达到统一准确率、样本完整性或标签覆盖率。三标签校准是能力记录，不再触发继续补强“美食”
样本或强制切换算法；通用语义预测将在后续阶段评估 Hugging Face 候选模型，并通过可替换 provider
边界接入。

样本从人工决定中按 `updated_at_ms DESC, asset_id ASC` 稳定选择，并把实际 Asset、
content revision、role、rank 写入不可变 revision。发布前要求所有样本的当前 Feature 可用。

### 5.2 评分正确性

- 输入必须是单个 active Tag 与最多 500 个显式候选 Asset ID；
- 排除样本自身、不可用/非当前文件资产、content revision 不匹配和已有人工决定的候选；
- 只比较完全相同 provider/request/preprocessing、element type/count 的 Feature；
- 写 prediction 前再次检查 model revision 仍为 current 且候选仍无人工决定；
- 同一请求重跑幂等；旧 revision 可保留但当前查询绝不回退展示；
- 浮点解析和距离计算必须拒绝非有限值、长度不匹配和损坏数据。

本切片只提供 Application/Infrastructure API 与集成测试，不接 SwiftUI Review Queue。

## 6. 最小测试门

每个切片执行一个 tracer-bullet 红灯后再实现，并只保留主路径、关键失败路径和相关回归：

- G：v003 文件升级保留事实；模型发布原子；人工决定遮蔽 prediction；
- H：真实临时 JPEG 生成后命中；content revision 变化不复用；来源文件 bytes/hash 不变；
- I：2 正 + 2 负可发布并使近正例候选排名为正；有人工决定的候选不写入；旧 revision 不展示；
- 每个实现切片 arm64 Debug build 成功；最终运行相关 migration/startup/tag/derived-image 回归；
- `git diff --check` 通过，工作区只保留既有未跟踪 `user/`。

## 7. 停止位置与延期

本轮在“后端可以对显式候选集合产生版本化 pending prediction”停止。以下继续延期：

- Review/Inspector AI 建议界面、置信强度文案和快捷键；
- 自动触发、全库调度、活动中心、暂停/取消与性能 envelope 基准；
- evaluation cohort、离线 metrics、阈值校准和代表样本多样性选择；
- Hugging Face 模型评估、下载/安装、许可证、权重校验与本地 runtime；
- PhotoKit、iCloud 下载与 `/Volumes/HDD2` 真实数据 smoke；
- 导出、FSEvents、相似组、线性分类器和近似最近邻。

这些延期不允许弱化人工事实优先、原图只读、缓存路径安全、数据库原子性或 Git 边界。

## 8. 实施与验收记录

| 交付 | Commit | 结果 |
|---|---|---|
| 实施规格 | `fe7b42c` | 冻结 G～I 范围、算法默认值、安全边界与停止位置 |
| Slice G | `08f67cd` | v004、五张 STRICT 表、Feature/Model/Prediction repository |
| Slice H | `d21af4a` | Vision Feature Print revision 2、只读来源校验、版本化外部缓存 |
| Slice I | `ace21f1` | 2+2 起步、每类最多 12、最多 3 邻居、500 个显式候选评分 |
| 失效覆盖 | `45501b6` | 证明 content revision 变化后生成独立 Feature，不复用旧 identity |

最终验证（2026-07-16）：

- `xcodebuild test -scheme ImageAll -destination 'platform=macOS'`：700 tests passed，0 failed；
- `xcodebuild build -scheme ImageAll -configuration Debug -destination 'platform=macOS'`：`BUILD SUCCEEDED`；
- 真实 Vision 集成测试只使用临时生成 JPEG；源文件 bytes 与修改时间保持不变；
- 未访问 `/Volumes/HDD2`，未接入 SwiftUI、PhotoKit、自动调度、FSEvents 或活动中心；
- entitlement、privacy manifest、依赖与签名策略均未变化；
- 未 push，既有未跟踪 `user/` 保持未触碰。

当前停止位置仍是“后端可对显式候选集合产生版本化 pending prediction”。下一步会进入
新前端功能模块，因此必须先与项目所有者讨论 Review Queue、Inspector 建议呈现、强度文案与
接受/拒绝交互，再编写 UI 实施规格。
