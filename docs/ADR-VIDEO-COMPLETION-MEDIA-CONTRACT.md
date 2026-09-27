# 视频补全决策：跨端媒体域与旧协议兼容

日期：2026-09-27。状态：实施中。范围：P1 第一切片。

生产领域已保存 `MediaKind`，但摘要与详情仅传资源格式 `mediaType`，网页以 MIME 前缀判断，导致 `public.mpeg-4`、`com.apple.quicktime-movie` 等真实 UTI 不能进入视频分支。

摘要与详情新增可选 `mediaKind`，Host 从领域事实明确投影 image / video；不修改 `mediaType` 的现有语义。可选字段允许新客户端解码旧 Host；旧客户端按既有 Codable / schema 忽略额外字段。

消费方优先使用显式媒体域。旧 Host 仅使用已知 UTI 白名单及 image/、video/ MIME 类型兼容推断；未知格式保持未知并显示不可用，不能默认当照片。协议未知的新媒体域不回退猜测。HTTP Content-Type 仍由媒体路由决定。

本切片不重写播放器或标签系统。协议兼容测试与 Web 消费分支证明这条契约，播放资源生命周期、Mac/iPhone 入口及持久整理闭环在后续 P1 切片验收。网页实现保留在专用工作区，主线集成单列，不因分支通过宣称目标完成。

## P1 Mac 共用播放器（2026-09-27）

图库、审核和瘦身大图使用同一个 `LibraryVideoViewingSession` 与 `AVPlayerView` 组件，复用 `LibraryVideoPlaybackProviding` 的本地只读资源租约，不另建来源数据库。系统控件负责播放／暂停、进度、音量和全屏；速度限定 0.5 / 1 / 1.5 / 2 倍。打开不自动播放，避免切换资产时突发原声；保留显式系统播放器入口。

前台播放器与静音悬停互斥。资产／内容修订切换、关闭、来源／媒体域切换与 App 失去焦点均清理当前 item 和租约；失焦后返回以新请求重新读取，播放仍由用户触发。异步准备使用请求身份检查，迟到的资源只释放，不接到新选择。旧视图拆卸仅可停止匹配的资产与修订。

本阶段仍采用既有 PhotoKit 本地 URL 路径，不触发 iCloud 下载；云端不可用单独提示。编辑后的非 URL AVAsset 支持与显式下载由 P2 明确。瘦身投影尚无修订字段，因此每次打开重新获取当前资源；后续完整字节去重必须补齐执行前的来源／内容修订复验，不能将此播放器视为去重证据。

## P1 iPhone 认证视频流（2026-09-27）

AVPlayer 不接收 Bearer URL、查询参数凭据或非公开的 AVURLAsset 请求头选项。`RemoteVideoPlayback` 通过内部 `imageall-video` scheme 的资源加载委托，复用 `RemoteLibraryClient` 的配对请求头、TLS pinning 与禁止重定向的 transport。单次读取上限 256 KiB，生产 URLSession transport 在读取过程中限制大小并取消未读响应；加载器串行处理分段请求，不保存整段原件或持久视频缓存。播放器前向缓冲提示 10 秒，此提示不代表系统解码器内存的严格配额。

能力通过新增可选 `videoRangeStreamingVersion=1` 字段声明，不增加会导致旧 Swift 客户端枚举解码失败的 capability 值。缺字段的旧 Host 明确显示升级提示。媒体路由在提供器具备修订事实时返回 `X-ImageAll-Content-Revision`，带 revision 的请求必须匹配；播放器拒绝没有修订头、修订变化、Range／长度／媒体类型不匹配的响应。旧无 revision 请求继续按既有路由服务。该目录修订保护不是完整文件摘要证据，来源文件同修订下外部改写的精确去重保护仍属 P4。

切换资产、退出预览、断开连接与进入后台时清空 AVPlayerItem 并取消加载请求。同一视频的标签／收藏刷新在媒体身份与修订不变时保持播放位置；不会因为更新整理事实自动从头加载。视频邻居不进入照片预览预取。云端原件不可用明确报错，不授权或触发下载。

## P2 文件夹视频内嵌时间与位置（2026-09-27）

P1 的 Web 资源集成与各端 UI 验收保留未完成状态；为缩短到最终可运行功能的路径，先并行推进不依赖这些事项的 P2 元数据纵切片（仍由同一代理顺序实施）。不据此跳过 P1 门禁。

- 复用 `FolderVideoMetadata` → `FolderMediaMetadata` → reconcile → `asset` / `asset_location`，不创建第二份位置事实。
- 时间优先 QuickTime `creationdate`，再读取标准 common creation date。只解析带明确 UTC 或偏移的 ISO 8601 字符串，保存 UTC 毫秒；无时区、缺失与畸形值保持 nil，不用文件时间或本机时区猜测。遵循 ADR-069。
- GPS 读取 QuickTime ISO 6709 十进制度格式，校验纬经度边界，允许可忽略的高度；度分秒和不明后缀明确不解析。本地来源仍登记现有 `embeddedGPS` provenance。缺 GPS 不影响视频可用性。
- 宽高继续使用视频轨 preferredTransform 后的尺寸；测试覆盖旋转 90 度。读取容器元数据不解码全片，不写来源媒体。
- 本切片覆盖新扫描及已有 reconcile 读取路径。历史有界回填、技术规格存储／展示、筛选、地图媒体范围与显式云端获取仍属 P2 后续必需工作；不能用本次提取通过代替整阶段完成。
