# ADR-099 App 更新后必须核对运行中的制作服务

2026-09-23。

现场问题：后台进程仍运行 payload 1e26fa… 的导演 1.2.0。App 已发布含 captionProtected/durationProtected 的新请求，而 helper 的 start 只要发现任何 running 服务就直接复用。旧导演在模型调用前按严格请求 schema 拒绝新增字段，返回 INVALID_REQUEST。

证据：只读失败请求 JSON 元数据，未读取派生照片内容。按旧转换方式复现 19 个 shots 的 additionalProperties 错误；按 1.2.1 转换后 schema 错误为 0。后台 capabilities 报告 pluginVersion 1.2.0，进程可执行路径证实为旧 payload。使用 finish-current 协议已让现场旧服务正常退出，未杀进程、取消活动工作或自动重发失败请求。

修复：helper 启动时比较 heartbeat PID 对应的实际可执行路径与本次 payload 安装路径。相同则复用；不同或不能确认则请求 finish-current 并等待最多 15 秒。若旧任务未结束，明确报告等待升级并阻止新提交；不强杀、不取消既有任务。旧服务退出后从新 payload 启动。App 同时在导出素材之前拒绝不支持字段保护的自动导演版本（低于 1.2.1），给出明确升级说明。

界面把终态成片与本次创作状态分开，标为“上次成片”，避免历史完成状态被误解为本次自动创作成功。当前失败记录不篡改、不自动重试；用户重新生成新请求后使用新服务。

验证：包含旧导演 1.2.0 提交前拒绝、无 requests 目录落盘，以及新版发布/返回/应用的 Swift 定向测试通过；Python 合成 SDK 往返测试通过。正式 Debug build 通过，helper 的 PID 路径检查与 graceful stop 分支编译通过。真实失败请求仅进行离线结构校验；没有加载照片文件或重新调用模型。未通过真实进行中的渲染任务验证等待升级分支，不把该场景记为现场通过。证据及旧 App 备份位于 `/Volumes/SSD1/ImageAll-artifacts/runtime-upgrade-20260923/`。

## 缓存编号缺陷的追加修复

随后现场仍显示原 requestID 的失败记录，且后台重启后仍为 1.2.0。进一步发现 embed.sh 复制的是 prepare.py 初次生成的 runtime-version；修改导演覆盖脚本后没有刷新这个编号。因此新版 bundle 虽含 1.2.1，却仍指向已缓存的 1.2.0 目录，上一轮仅检查运行路径的修复不足。

改为每次嵌入前应用受版本控制的 integration overrides，并对实际 Runtime 内容生成 SHA-256 身份，包含相对文件名、文件内容和符号链接目标，忽略运行生成的 pycache/pyc。prepare stamp 不再决定安装目录。新增回归证明 prepare stamp 不变时修改导演源码必定改变内容身份。helper 增加受同一 launcher-request nonce 校验约束的无界面启动入口，用于验证服务升级，不自动发布创作请求。

追加现场验收：旧 payload 1e26fa… 已经 graceful drain；通过 nonce 校验的 helper 启动入口启动新内容身份 1fc609e…，并保留现有配置及可选服务偏好。随后核对 heartbeat PID 的实际命令路径为新安装目录、capabilities.pluginVersion 为 1.2.1、安装脚本字节与受版本控制的 override 一致。使用该已安装 runtime 的 Python 与 engine 跑合成 SDK 往返测试通过（本地 fixture 模型，不读取真实照片、不调用付费模型）。旧失败请求 ID 未改写、未重试。日常 App 已更新并签名验证通过；当前 App 的原生请求协议未再改变，可直接生成新请求，无需为了本次后台修复再次重启。现场证据位于 `/Volumes/SSD1/ImageAll-artifacts/payload-cache-20260923/`。
