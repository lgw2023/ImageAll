# ADR-086：独立本地创作插件与有界方案交换

2026-09-20，已实施并通过合成素材联合验收。基线：ImageAll ca76bb84 / OpenMontage 994ad1e。

## 现场差异与决定

private-photo-atelier 1.1 的创作智能仍由 Agent 读取技能驱动。其视觉 API 工具不生成完整制作方案，private_photo_atelier CLI 只重渲染手工冻结方案。没有可恢复、受权限约束的无人值守导演。产品因此明确区分“等待创作 Agent”和“自动渲染”。本轮不编写伪装成创作智能的模板调度器。

ImageAll 权威管理主体、可信时间地点、候选和原图访问、用户锁定/排除/编辑及 StoryProject。插件只接收用户发布的派生素材，负责观察与创作建议，不回写图库事实。双方只依赖 docs/contracts/creative-plugin-v1.json 和文件交换语义；App 不读取插件源码、pipeline 或执行 Atelier 脚本。

先提供最小 `editable-story-v1` 方案能力：当前故事照片构成本次明确有界候选，Agent 可选择子集、编排章节、字幕和逐镜时长，保留用户锁定和明确修改。范围不等于整个主体图库。任意 Atelier 代码、自由布局、裁切和运动尚不属于该可编辑 profile；必须明确报不支持，不能静默丢弃。Phase6 审美选择不写成 ImageAll 规则。

## 文件交换与兼容

沿用用户已授权的执行器任务根，新建 `creative/capabilities.json` 和 `creative/requests/<requestID>/`。不修改旧任务 v1.1 或 StoryRenderPackage v0.1。插件可独立更新；capabilities 声明精确协议/profile、插件版本、planningMode=agent-assisted、自动创作=false。未知版本/profile 拒绝，旧工程继续使用原渲染路径。

App 在 staging 写入 request.json、package/story.json 及规范化素材，最后原子重命名目录；request 的哈希由 StoryProject receipt 留存，complete.json 为发布标记。插件验证清单和哈希后初始化自身 private-photo-atelier workspace；创作 Agent 按原生阶段技能/checkpoint/decision_log 工作。插件 complete 操作只验证并发布已有方案，不自动做导演判断。plan.json + ready.json 绑定请求哈希、版本、素材和输出哈希；相同完成命令幂等，不同内容冲突拒绝。取消标记优先于方案使用；取消后重试使用新 ID，重开 App 从持久化 receipt 恢复。创作等待没有假进度或假心跳；确定性渲染的进度/取消/恢复继续采用既有 v1.1。

请求携带用户意图、主体、目标、事实引用、候选版本/hash、锁定/明确编辑约束。v1 只声明 externalSendAllowed=false；旧第六阶段外发许可不转为常驻许可。将来云创作必须增加独立授权契约，明确 provider/model/发送集合/成本。本轮验收使用合成素材，无私人照片外发。

App 导入前复核 request/plan/hash/引用、时间顺序、锁定/明确编辑与当前项目指纹、素材版本，拒绝过期方案。观察、推断、不确定性只保存在创作说明，不写入事实。用户修改后，重新由 ImageAll 导出冻结 v0.1 包；旧执行器按其精确 revision 渲染并返回校验结果。方案 profile 的默认呈现由既有 renderer 定义，不宣称 Atelier 已接入。

## 本轮接受与后续

本轮接受：日常 App 输入意图、发布限定范围、真实等待 Agent、接收校验方案、修改保存重开、冻结制作和打开成片；合成素材主路径及一次过期或取消恢复验证。既有项目兼容、拒绝越界/不兼容是必要测试。

尚待独立阶段：无人值守创作 Agent 运行时（身份、授权、费用、进程权限及恢复）；可编辑且可重渲染的 Atelier 场景 profile；正式打包/AGPL、Remotion、FFmpeg 和字体等许可审查。当前仅独立本地原型，不因许可猜测停摆，也不宣称可随 App 分发。


## 验收记录

唯一报告：`/Volumes/SSD1/ImageAll-Story-Interop/phase7/engineering/JOINT_ACCEPTANCE.md`。
日常 App 发布 18 张合成照片请求，Agent 原生四阶段返回 6 张/5章方案；App 校验、用户改字幕、保存重开并提交冻结任务，产出 596 帧 / 19.866667 秒 H.264 无音轨视频，App 核验后打开播放到片尾。协议 schema SHA-256：`cca07bd8aba5bba9ae69ff08e2cb8fa79d05b1cb7ad2e6fb6097702b6082a254`。取消→新ID重试、幂等完成和聚焦测试已核验。通过范围仅合成素材的 Agent 协作插件链路，不含自动导演或完整 Atelier 编辑/渲染。
