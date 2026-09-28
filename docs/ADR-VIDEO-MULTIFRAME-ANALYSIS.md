# 视频有限多帧分析（P5）

状态：实施中，2026-09-28，仅 Mac。

## 当前差异与决策

现有视频分析使用 videoPoster.v1 代表图，不能证明后段内容已分析。保留旧结果和模型身份，增加独立 videoFrames.uniform5.512.jpeg80.v1 输入。新入口必须由用户显式选择；升级不自动扫描。多帧候选不写精确重复证据表、不进入精确清理路径。

首个采样实现选择 5%、25%、50%、75%、95% 的确定性时间点，距末端至少 min(100ms, duration)，相邻请求至少 250ms。每段最多 5 次解码请求，图像最长边 512，JPEG 质量 0.8，总编码数据上限 8 MiB。解码失败或实际时间重复会跳过并记录请求时间，全部失败则拒绝结果。纯黑画面可能是合法内容，不凭颜色删除证据。保存请求时间和解码实际时间，后续播放使用实际时间。

逐帧 autoreleasepool 限制应用持有的图像中间量；AVFoundation 内部 GOP 解码、内存和同步调用耗时不受这一帧数上限保证。取消在请求前、解码后及发布前检查，本首切片不宣称能中断正在进行的同步解码。持久缓存、复用、内容修订复核、任务调度、训练/推理聚合、审核时间点入口仍须接线，不能据此称 P5 已交付。

只接收调用方已授权且仍持有的本地描述符，临时扩展名链接在任务独立目录，结束清理；不读取 PhotoKit、不开网络、不修改源文件。现有封面生成器不改动。

## 首次合成测量

2026-09-28，1 秒 MP4 请求 3 帧并成功解码，实际时间 33/500/733 ms，总 JPEG 22,294 字节，0.139826 秒。该值仅支持首轮预算选择，不代表真实库性能。构建成功，两项定向 XCTest 通过（采样/取消及既有容器差异回归）。后续按目标补齐语义对照与全链测量，必要策略变更必须换版本。

## 文件夹检查点与缓存（2026-09-28）

新增 V057 video_analysis_frame，独立保存 asset/revision/policy/source-identity/requested-time/actual-time/JPEG/SHA。FolderVideoAnalysisService 通过授权根目录的 no-follow 文件描述符解码，采样前、逐帧保存前和返回前复核目录定位、目录数据库事实及包含 ctime 的物理身份。身份同时含来源、相对路径、时长；修订、策略或物理身份变化不会复用旧帧。缓存只保存逐帧检查点，不代表资产分析完成。

缓存存于 SQLite 事务内，无外部路径；每资产最多 5 帧、有效 JPEG 总量最多 8 MiB，全库有效 JPEG 总量最多 64 MiB，按最旧写入淘汰。SQLite 文件、WAL、页和空闲页的磁盘占用不等同于 JPEG 有效载荷限额，后续资源验收须分别报告。保存时淘汰该资产其他修订/策略/物理身份的缓存；历史分析 Run 和旧封面结果不改写。

直接 XCTest 3/3 通过：取消后续跑复用 1 帧、解码 2 帧；全缓存再跑解码 0 帧；修订更新解码 3 帧；源文件变化拒绝；数据库重开幂等。策略/来源键不匹配返回空缓存。本轮未接 PhotoKit 多帧读取、特征/模型聚合、用户策略切换、审核帧或内容候选入口，这些仍是 P5 必需交付。

## 多帧图像特征与表示（2026-09-28）

复用现有 VisionFeaturePrintGenerator（request revision 2）。各帧向量 L2 归一化，逐维均值后再次归一化，形成唯一资产级输入；每帧向量与实际时间保留。表示身份 `videoFrames.uniform5.512.jpeg80.v1/vision-r2/mean-unit-v1`，训练/推理必须以同一身份取 modelInput；旧 videoPoster 身份明确拒绝。当前底层接口已实现，生产训练/推理调用和持久化尚未接线，因此不得称模型兼容门禁已端到端完成。

内容候选分数为双向最佳帧余弦覆盖均值，并保留最佳帧对时间点。单个共有封面不足以代表整段覆盖；无序帧覆盖不识别运动顺序，不承诺变速/裁剪/片段重叠检测。后续候选服务仍须加时长约束并与精确清理入口隔离。

`video-frame-features-build.log` 构建成功；`video-frame-features-tests.log` 2/2 PASS，真实 Vision 对三帧输出 768 维特征，身份拒绝、取消、自相似和原缓存续跑通过。人工正交向量对照仅共享封面时分数 0.5，属于聚合规则验证；不是“同封面不同内容”真实视频对照，也不是语义识别或准确率证据。目标要求的后段目标视频、单帧/多帧对比仍待完成。

## Mac 主动入口

查看器新增显式多帧分析、取消、复用有效帧重跑和代表帧时间点定位。初始化和浏览不自动分析；耗时工作使用后台 Task，取消传至采样/特征检查点。仅当前详情匹配、有时长的文件夹视频开放，未支持来源保持禁用。点击时间点核对播放身份、非负及小于资源实际时长，定位后保持暂停，不自动播放音频。现阶段帧缓存持久、展示和特征集合为本次结果；正式建议/模型及跨次证据读取仍待实现。

## 实际视频对照测量

三段 4 秒几何图形视频验证后段时间覆盖和同开头内容区分：红圆参考的旧 poster 余弦 0.524054，多帧最佳帧 0.991022（3000ms）；同开头视频单帧余弦 1.0，多帧覆盖 0.752481。采样五帧 21,458 字节、0.099672 秒，不含 Vision/素材编码。参考匹配为特征检索对照，不宣称模型学会“圆”标签；分数非概率且不设生产阈值。日志与原始对照素材在 video-completion-20260927/content-controls；具体测量为 fixture-only。

## 主动重建范围

多帧菜单明确区分复用和强制重建。强制操作在授权来源、媒体身份和取消检查通过后，仅丢弃同一 asset/revision/policy/source-identity 检查点，再重新取帧；取消后的新检查点仍可续跑。不会自动重建全库，也不删除旧 poster 或原件摘要。该选项不等于模型策略切换；完整新旧训练/推理策略入口仍需实现。

## 完整特征证据缓存

V058 新表按资产保存当前表示的完整特征，关联修订、来源身份及输入帧摘要；帧时间点与输入一一对应，载荷 SHA 核验失败则重算。缓存 JSON 有限长、向量须有限值和同维，最多有效 16 MiB，超限按写入时间淘汰。历史训练 Run、旧 poster 特征和精确去重事实不改变。Mac 入口统一调用 analyzeWithFeatures，在原文件授权与复核范围内生成/持久化；重开后经来源复核复用。此缓存仍属分析证据，不授予模型兼容性、标签接受或清理权限。

## 独立内容候选首版

用户显式触发，从当前表示已分析且修订仍一致的视频中，选最近写入的最多 20 项比较，时长必须在当前视频 ±20% 内。超过范围明确显示未穷尽；未分析资产不自动入队。候选需重新验证授权来源并读取/复用当前特征，失效按跳过计数，取消传播。比较完成再次复核当前视频特征未变化。

按双向覆盖分数降序展示名称、当前/候选最佳帧时间点；分数不是概率，不设未经真实数据校准的自动接受阈值。当前时间点可 App 内定位，候选通过既有系统播放器打开（不承诺系统播放器自动跳到显示时间）。与精确去重服务无写入依赖，无清理按钮。Mac 现有单项打开只接收已加载分页资产，故不能直接用于全库已分析候选；系统播放器通道避免无响应入口。

## 现有模型管线身份审计与门禁

发现 PersonalizedSuggestionService 只核对维度和内容修订，候选载荷的 provider/request/preprocessing 身份没有与固定旧模型匹配；FullLibrarySuggestionsHandler 在生成样本注册时重新构造默认身份，可能掩盖不同表示。因此在两个管线的每次特征加载后核对资产 ID 和完整旧表示身份，使用明确 incompatibleFeatureIdentity 拒绝。该门禁是显式策略接入前的正确性要求，不将多帧接入降级为永久不可用。

现有 feature/tag_model_revision/tag_model_sample 固定 provider=vision-feature-print，但 request/preprocessing revision 是正整数；多帧使用同 Vision 编码器时应保留 provider 并选择独立 preprocessing revision，同时模型发布/读取、冻结任务载荷和训练 artifact 都保存该版本。后续需将固定常量替换为用户选择并冻结的表示，保留旧默认值和历史 Run；不能只替换 loader 后沿用默认样本注册。当前尚未实施该策略切换。

## 显式模型表示版本首接入

PersonalizationRepresentation 固定 legacy=1、videoMultiFrame=2，对应 preprocessing_revision。provider 仍为 vision-feature-print、Vision request revision 仍为 2；预处理 2 精确对应 videoFrames.uniform5.512.jpeg80.v1/vision-r2/mean-unit-v1。VideoMultiFrameFeatureLoader 仅加载视频，实际调用受来源复核的多帧服务，将聚合向量注册到既有 feature/安全向量缓存；不支持来源报错，不回退单封面。

直接 PersonalizedSuggestionService 必须显式选择 videoMultiFrame，样本和候选均校验相同表示，照片域拒绝该策略；ModelRevisionRegistration/发布仓储保存所选版本，并逐个匹配样本。旧默认保持版本 1、历史 Run 不改写。全库后台任务目前仍冻结旧流程，训练 artifact 与 Mac 正式策略选择尚待接入，不将直接服务通过等同于完整训练流水线交付。

## 后台冻结合同

FullLibrarySuggestions 合同 1 绑定 legacy，合同 2 绑定 videoMultiFrame 且仅视频域。表示写入 payload 而非运行时读取 UI 偏好。新字段旧合同可省略，新合同不可省略；保留 job envelope version，使旧 handler 依据旧 contractVersion 门禁明确拒绝新合同。采样/候选与模型发布全部取同一冻结表示，生产 dependencies 注入独立多帧 loader。

当前 tag/media coalescing key 保持原契约。正式用户切换入口必须在已有同标签媒体任务未结束时处理策略冲突，不得把不同策略静默合并成“已按新策略提交”；该入口和训练 Run 冻结配置将下一步实施。默认旧任务行为不变。

## 正式选择与训练 Run

视频 Feature KNN 确认页显式选择单封面或有限多帧，默认旧策略；选择捕获到确认对象并传入正式 ReviewPort。任务参数与 TrainingRun config 同步冻结表示及预处理版本。现有同 tag/media 活跃任务阻止任何新提交（包括策略不同），事务竞争同样返回 activeJobConflict；不按新策略提示成功却复用旧任务。历史配置不回填、不改写。未实现新策略的其他 ReviewPort 实现会拒绝多帧请求。

## Photos 本地资源边界

PhotosVideoAnalysisSourcePort 只提供受控本地原件闭包，不接受云端下载授权。PhotoKit 请求 version original/network false，持有返回的 AVAsset 至闭包结束；非 AVURLAsset、本地文件外 URL 或云端不可用均拒绝。读取前捕获资源身份、完成后复核授权及身份；后台等待可取消且有 300s 请求等待上限。该入口尚未作为缓存/训练 UI 的可用声明；实际整合需先通过合成 reader 的资源变化/修订/取消验证。

## Photos 多帧统一分析

既有服务增加 Photos 分支（内部类型名暂保留 FolderVideoAnalysisService），在 PhotosVideoAnalysisSourcePort 授权闭包内持有原件描述符；缓存键除 catalog asset/revision 外，包含 source/local ID、资源身份、时长、类型、inode/ctime/mtime/size。每帧、特征完成和返回前复核 catalog/文件，PhotoKit adapter 在闭包结束另复核系统资源身份。Photos 结果与文件夹使用相同表示、预算及正式版本2 loader，无云端回退。

Mac 查看器、策略确认和已分析内容候选可接 Photos 本地视频。云端不可用返回错误而不下载；原件不是当前编辑渲染效果，仍遵循已有原件播放器语义。工程验收使用替身 reader 和合成 MP4，真实 PhotoKit/iCloud 系统流程保持 NOT_RUN。

## 建议输入证据冻结

预测事务保存 VideoPredictionEvidence：资产修订、表示身份、实际向量摘要及实际采样帧时间/JPEG 摘要。与当前分析缓存分离；旧预测没有证据，不自动回填。真实多帧 loader 生成证据，评分校验向量摘要，发布校验域/模型版本/资产修订。该证据表示全部聚合输入，不把最佳匹配帧冒充模型因果解释。审核后续只能使用摘要匹配的缓存图像，缺失应明确显示无法还原，不用新分析替换历史输入。
