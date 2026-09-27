# 视频补全决策：跨端媒体域与旧协议兼容

日期：2026-09-27。状态：实施中。范围：P1 第一切片。

生产领域已保存 `MediaKind`，但摘要与详情仅传资源格式 `mediaType`，网页以 MIME 前缀判断，导致 `public.mpeg-4`、`com.apple.quicktime-movie` 等真实 UTI 不能进入视频分支。

摘要与详情新增可选 `mediaKind`，Host 从领域事实明确投影 image / video；不修改 `mediaType` 的现有语义。可选字段允许新客户端解码旧 Host；旧客户端按既有 Codable / schema 忽略额外字段。

消费方优先使用显式媒体域。旧 Host 仅使用已知 UTI 白名单及 image/、video/ MIME 类型兼容推断；未知格式保持未知并显示不可用，不能默认当照片。协议未知的新媒体域不回退猜测。HTTP Content-Type 仍由媒体路由决定。

本切片不重写播放器或标签系统。协议兼容测试与 Web 消费分支证明这条契约，播放资源生命周期、Mac/iPhone 入口及持久整理闭环在后续 P1 切片验收。网页实现保留在专用工作区，主线集成单列，不因分支通过宣称目标完成。
