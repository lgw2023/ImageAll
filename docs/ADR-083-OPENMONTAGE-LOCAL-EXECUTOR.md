# ADR-083：时光故事接入本地 OpenMontage 执行器

- 状态：Accepted
- 日期：2026-09-19
- 范围：ImageAll 原生 macOS App、本地任务目录交换
- 相关：ADR-081、ADR-082、`LOCAL-TEST-DATA-SAFETY.md`、OpenMontage 任务协议 v1

## 目标与非目标

第三阶段允许用户在系统目录选择器中授权一个任务根，随后从时光故事工作区选择
“OpenMontage 本地制作”及横屏或竖屏，发布一次冻结任务，查看进度或取消，并在执行器验证成功后
打开、在 Finder 中显示或另存成片。

ImageAll 不打包或启动 Python、Node、Chromium、FFmpeg、Remotion 或 OpenMontage，不关闭 App
Sandbox，不从故事包读取命令，不在生产代码中写开发机路径，也不假定沙盒 App 可以启动任意解释器或
浏览器。执行器由用户独立启动；首版一个执行器同时只运行一个任务。

原生 AVFoundation MP4 导出和独立 `StoryRenderPackage v0.1` 导出继续保留。执行器离线或失败时
只给出可操作错误，不静默改用原生引擎重做。

## 安装版本来源核查

2026-09-19 核查 `/Volumes/SSD1/ImageAll-Daily/ImageAll.app`：

- `Contents/MacOS/ImageAll` SHA-256 为
  `eabd170fccc688ecef1f0d9d3c3f7a41058973dcfeb46f32a7e04865ad64c86e`；
- 同一 App 内 `Contents/MacOS/ImageAll.debug.dylib` SHA-256 为
  `bc309be07895ea0ca3443ee1b7fbecfb89e08f923fbc76ecbff46a466fd7996a`；
- `codesign --verify --deep --strict` 通过，签名时间为 2026-09-18 16:34:00 +0800；
- 当前 App 的直接安装前备份是
  `/Volumes/SSD1/ImageAll-Daily/ImageAll-before-story-phase2-progress-fix-20260918-1636.app`。

因此 `eabd170f…` 与 `bc309be0…` 是同一安装包内不同 Mach-O 文件的哈希，不能据此断言安装包
损坏或发生未记录替换。仓库提交时间、备份链和签名时间支持当前安装版来自第二阶段最后一次进度修复
构建；但现有安装目录没有包含源码提交号的独立、签名 provenance 清单，所以仅凭 App 包不能反向证明
它对应哪一个源码提交。第三阶段安装时必须登记启动可执行文件、Debug dylib、签名和源码提交四类身份。

## 协议分层

故事内容继续使用 ADR-082 冻结的 `StoryRenderPackage v0.1`，Schema SHA-256 固定为
`884a6fed3eb4d8cf3b37c450b8a9a4e2d21782220532a66d21dccdf8fe696841`。任务协议独立版本化，
只描述执行器能力、任务身份、发布完成性、状态、取消和验证结果，不给故事 Schema 增加进程、状态或
本机路径字段。

OpenMontage 任务协议 `1.1` 是线格式的权威来源，冻结于 OpenMontage 提交 `1dbf43f`；机器 Schema
路径为 `schemas/integrations/story_executor_task_protocol_v1.schema.json`，SHA-256 为
`da49966ac4b60c9a1b597768ff898eadf1c9c063bb91e95e4bb9754e5802e912`。执行器实现提交为
`2bfc6d1`，进度单调修复为 `f3661fa`。初版 `1.0` 只通过被哈希覆盖的 `task.json` 间接携带
producer 和故事身份，没有满足本阶段对完成信封的显式字段要求，未被 ImageAll 生产接入；`1.1`
显式增加并交叉校验这些身份，字段含义已经冻结。

精确目录为 `<root>/executor/**`、`<root>/tasks/<taskID>/submission/**`、
`<root>/tasks/<taskID>/requests/cancel.json`、`<root>/tasks/<taskID>/state/**` 和
`<root>/runs/<taskID>/<adapter-run>/**`。ImageAll 只写 submission 与单任务取消请求，OpenMontage
只写 executor、state 与 runs。

## 目录授权与写入权

1. 用户通过系统目录选择器选择任务根；ImageAll 保存 app-scoped 可写 security-scoped bookmark。
2. 每次检查、提交、查询、取消和取结果都重新解析 bookmark，在访问期间持有 scope；失效 bookmark
   要求重新授权，不退化为任意绝对路径访问。
3. 输入、状态、取消和结果路径都必须经过标准化并证明位于已授权任务根中。符号链接、`..`、绝对路径
   和未知协议路径不得绕过根边界。
4. 生产者只登记本次任务明确生成的 request、故事入口和故事素材；不递归收集 Finder 元数据、隐藏
   暂存目录或历史交付。
5. ImageAll 只写协议指定的 producer 区域和取消请求；OpenMontage 只写 executor 状态、事件、报告和
   结果区域。输入完成发布后只读。

## 原子发布与哈希覆盖

ImageAll 先在本次 taskID 的暂存区域导出完整故事包并完成内部校验，再写任务请求和按协议排序的文件
清单。清单覆盖请求及故事包的全部明确文件，但不包含清单本身、完成记录、状态、事件、取消请求或执行器
产物。完成记录最后原子发布，包含 producer、deliveryID/taskID、任务协议版本、`complete` 状态、
故事入口、故事 Schema 哈希和文件清单哈希。执行器只能消费完成记录存在且全部哈希通过的任务。

任何取消、导出失败或校验失败都不能发布完成记录。清理只使用本次内存中登记的暂存 URL 和产物清单；
不得递归清理任务根、其他 taskID 或第二阶段历史目录。

## 生命周期与身份

ImageAll 领域状态至少包含：准备素材、等待执行器、制作中、检查成片、成功、失败、取消，以及“执行器
离线/状态过期/中断但结果未知”的非成功呈现。线协议的阶段名称由适配层映射为这些自然语言状态。

- `taskID` 是一次尝试的身份；`projectID` 是故事项目身份；`projectRevision` 是本次冻结渲染内容身份，
  三者不得互相替代。
- 提交捕获 `TimeStoryProject` 值快照。后续编辑不会改变已发布任务；新 revision 使用新 taskID。
- UI 和任务端口均做重复提交保护。相同 taskID 不重提；状态不确定时不自动创建新任务。
- 终态单调：成功、失败、取消不能被迟到的进度覆盖。执行器离线、心跳过期、进程异常或缺少验证记录
  不能显示成功。
- App 重开后从已授权任务根重新发现并关联 projectID 对应的最新任务；只恢复观察，不重新提交。
- 取消通过该 taskID 的协议文件进行，不按进程名、解释器名或浏览器名终止进程。

## 成功结果门

ImageAll 只有同时满足以下条件才显示成功并开放结果操作：

1. 执行器状态是协议定义的成功终态，并有成功验证记录；
2. 结果中的 taskID、projectID、projectRevision 与本地冻结任务一致；
3. 横竖画幅、30 fps 和总帧数与故事包一致；
4. 结果相对路径经标准化后仍在该 taskID 的协议结果目录内；
5. 文件存在，SHA-256 与结果记录一致，且本机媒体读取能够复核尺寸、帧率和帧数。

打开、Finder 显示和另存都使用同一经过验证的 URL。另存使用系统目录选择器取得目标文件夹的写入
授权，并在其中选择文件名；先写该目录内的暂存文件并核对哈希，再原子发布。同名目标存在时拒绝覆盖，
要求用户更换名称；不从未验证的状态或任意返回路径打开文件。仅由保存面板选中单个目标文件，不会
授权在其父目录创建暂存文件，因此不能用单文件授权冒充目录授权。

## 界面

- 设置中独立显示“OpenMontage 本地制作”：任务目录、连接状态、协议/Schema 能力、刷新和重新授权；
  离线、依赖缺失、协议不兼容与授权失效给出不同提示。
- 故事工作区明确区分“原生制作”“OpenMontage 本地制作”和“导出独立故事包”。
- 用户只看到准备素材、等待制作、制作中、检查成片等自然语言；Python、Schema、PID、进程组仅进入
  诊断证据，不进入日常制作阶段文案。
- 运行任务显示冻结 revision 是否仍与当前编辑内容一致；旧任务结果不会覆盖新编辑或新任务。

## 验收与完成声明

自动化只使用临时任务根、模拟执行器和合成媒体，覆盖原子发布、目录逃逸、重复提交、状态单调、取消、
离线/过期、重启恢复、revision 隔离和结果验证。随后必须由实际安装的日常 App 发布合成短片、约 60 秒
横屏、竖屏和取消任务，由真实 OpenMontage 执行器消费并回写；还要验证执行器中断、App 重开恢复和
打开成片。

模拟执行器通过、ImageAll 单侧构建通过或 OpenMontage 单侧就绪都不能声明第三阶段完成。真实板栗素材
不在本轮授权内，也不用于自动化或联调。
