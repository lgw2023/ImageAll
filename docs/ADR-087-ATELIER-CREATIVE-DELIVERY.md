# ADR-087：完整 Atelier 创作版本的本地交付

2026-09-20。状态：实施中。适用于 ImageAll 与可信本地 OpenMontage checkout 的联合开发。

## 现场差异

`editable-story-v1` 只交换已入选镜头的子集、章节、字幕和时长；ImageAll 的 v0.1 故事包固定为单照片 contain、轻推和 cut/fade。OpenMontage 已有私有照片 pipeline 与项目级 Remotion Atelier 入口，但其示例 Composition 不实现多图布局。上轮 26 张已确认照片中只有 14 张进入插件候选，最终成片 10 张、静音 43.866667 秒。旧协议与成片保留原义。

## 决定

增加独立的 `atelier-project-v1` 创作交付 profile，协议 `2.0`，不修改 v1 schema。ImageAll 发布当前用户确认的有界候选快照及锁定、排除、意图和事实引用；候选与已选镜头分开，最多 26 张。没有由用户确认的更大范围时，App 不扩展日期或图库。OpenMontage Agent 使用原生 `private-photo-atelier` 的 idea → scene_plan → assets → edit → compose/review 阶段与检查点，冻结完整项目版本后交付可读摘要、项目清单、成片和出处。`automaticPlanning=false`，App 只显示 Agent 协作状态。

App 不导入任意 Atelier 场景到逐镜头编辑器，也不执行交付的代码。第一版编辑闭环是保存创作版本、审片、提交文字修改意见、产生新版本并保留旧版。渲染仅由受信任的本地 OpenMontage checkout 在独立进程执行。进程隔离不是 OS 沙箱，不构成插件分发安全承诺。

请求绑定 requestID、projectID、requestRevision、原项目 fingerprint、scope digest、逐素材 contentVersion 与 SHA-256、可靠时间及地点来源、锁定/排除约束、目标规格和意图。发布目录原子出现。交付先冻结完整渲染输入：入口代码、所有本地导入、props、字体、素材与依赖锁文件；清单列出相对路径、大小和 SHA-256，并给出 revision hash。任何缺失、越界、符号链接、远程依赖或 hash 变化都拒绝。成功版本和成片不可被重试覆盖，修改产生新 requestRevision 和新 projectRevision。

App 提交新制作前要求请求仍匹配当前项目 fingerprint、候选 scope 与用户约束；已完成的旧版本可继续读取摘要和核验成片，但明确保留其来源版本，不能悄悄套用到新编辑。结果绑定项目 revision、渲染入口、运行时版本、画幅、帧率、帧数和文件 hash。取消不能生成假成功。私有媒体和完整项目只放在隔离任务目录，不入 Git。旧项目、`editable-story-v1` 和简易本地制作继续可用。

## 验收界限

先用合成图证明完整项目冻结、越界/篡改拒绝、真实 Composition 的多图或非固定镜头表达、渲染结果核验及 App 版本闭环。真实旅行试制仅用本轮 26 张已确认范围；现有规范化副本优先，不足时只经合规 App 读取补齐。静音 A/B/C 分别归因于旧基线、同素材新镜头表达和新选片。视觉自审、完整播放与用户审美反馈分别记录。缺项如实标未执行，不把工程成功写成审美通过。

本轮运行证据与验收状态统一记在私有的 [JOINT_ACCEPTANCE.md](/Volumes/SSD1/ImageAll-Story-Interop/phase8/atelier-20260920-01/JOINT_ACCEPTANCE.md)；仓库不保存私人素材或成片。
