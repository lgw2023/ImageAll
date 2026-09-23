# ADR-099 App 更新后必须核对运行中的制作服务

2026-09-23。

现场问题：后台进程仍运行 payload 1e26fa… 的导演 1.2.0。App 已发布含 captionProtected/durationProtected 的新请求，而 helper 的 start 只要发现任何 running 服务就直接复用。旧导演在模型调用前按严格请求 schema 拒绝新增字段，返回 INVALID_REQUEST。

证据：只读失败请求 JSON 元数据，未读取派生照片内容。按旧转换方式复现 19 个 shots 的 additionalProperties 错误；按 1.2.1 转换后 schema 错误为 0。后台 capabilities 报告 pluginVersion 1.2.0，进程可执行路径证实为旧 payload。使用 finish-current 协议已让现场旧服务正常退出，未杀进程、取消活动工作或自动重发失败请求。

修复：helper 启动时比较 heartbeat PID 对应的实际可执行路径与本次 payload 安装路径。相同则复用；不同或不能确认则请求 finish-current 并等待最多 15 秒。若旧任务未结束，明确报告等待升级并阻止新提交；不强杀、不取消既有任务。旧服务退出后从新 payload 启动。App 同时在导出素材之前拒绝不支持字段保护的自动导演版本（低于 1.2.1），给出明确升级说明。

界面把终态成片与本次创作状态分开，标为“上次成片”，避免历史完成状态被误解为本次自动创作成功。当前失败记录不篡改、不自动重试；用户重新生成新请求后使用新服务。

验证：包含旧导演 1.2.0 提交前拒绝、无 requests 目录落盘，以及新版发布/返回/应用的 Swift 定向测试通过；Python 合成 SDK 往返测试通过。正式 Debug build 通过，helper 的 PID 路径检查与 graceful stop 分支编译通过。真实失败请求仅进行离线结构校验；没有加载照片文件或重新调用模型。未通过真实进行中的渲染任务验证等待升级分支，不把该场景记为现场通过。证据及旧 App 备份位于 `/Volumes/SSD1/ImageAll-artifacts/runtime-upgrade-20260923/`。
