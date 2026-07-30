# ADR-048：Mac Host 同源 Web Companion

> 状态：已决定（2026-07-30，项目所有者批准独立 worktree 并行实现）
> 相关：`docs/ADR-043-MAC-HOST-IOS-COMPANION.md`、
> `docs/ADR-044-MAC-HOST-COMPANION-R3.md`、
> `docs/ADR-047-MAC-HOST-CLOUDFLARE-PUBLIC-TUNNEL.md`

## 背景

Mac Host 已通过 `https://imageall.ultrahardcore.net` 暴露现有 Companion API。网页端可以复用
图库、缩略图、预览、标签、审核、任务和 WebSocket 能力，显著缩短手机可用界面的交付路径。

项目所有者明确：

- Web Companion 与原生 iOS Companion 在独立 worktree 中并行开发，互不替代或阻塞；
- 不要求 Mac App、Host 或 Cloudflare Tunnel 离线后网页仍可使用；
- 网页视觉应延续 Mac 端现有风格，不建立第二套设计语言。

## 决策

### 1. 产品和部署形态

- Mac App 继续是唯一数据与写操作权威；Web Companion 不保存或同步 SQLite。
- Web Companion 由 `RemoteHTTPServer` 在同一 Host、同一公网域名下直接托管。
- 不增加云数据库、静态站点托管服务、Service Worker 离线缓存或后台同步。
- 原生 iOS 工程和协议继续独立演进；本切片不修改 `ImageAllMobile`。

### 2. 首个纵向闭环

首版必须完成：

1. 用户在 Mac 设置中开始短时配对，并复制带 URL fragment 的网页配对链接；
2. 手机或桌面 Safari 打开公网域名，以一次性配对令牌建立浏览器会话；
3. 网页加载真实来源、标签和资产分页网格；
4. 用户打开单张资产检查器，查看预览与标签状态；
5. 用户执行确认、拒绝或清除标签，Mac Host 持久化结果；
6. WebSocket 收到 Host 事件后刷新相关投影。

配对令牌只放在 `#pair=...` fragment 中，不进入 HTTP 请求、Cloudflare 日志或 Referrer。

### 3. 浏览器会话与安全

现有原生客户端继续使用 `Authorization: Bearer`。浏览器新增同源会话适配层：

- 配对成功后把 access token、refresh token 和 device ID 写入 `Secure; HttpOnly;
  SameSite=Strict` Cookie，JavaScript 不持有长期令牌；
- access Cookie 可用于现有 HTTP API 和浏览器 WebSocket 握手；
- access 过期时，同源 refresh 路由旋转 refresh token 并重发 Cookie；
- Cookie 鉴权的写请求必须通过 `Origin` / `Host` 同源校验；原生 Bearer 请求不受影响；
- 静态资源使用严格 CSP、禁止 framing、禁止 MIME sniffing，所有响应继续 `no-store`；
- Web 静态资源只按固定白名单路径提供，不接受任意文件路径。

浏览器登出只清除本机 Cookie；若要撤销长期授权，仍在 Mac 设置的“已配对设备”中撤销。

### 4. 视觉与交互

网页不是独立品牌站，而是 Mac 图库工作区的响应式延伸：

- 使用系统字体、系统蓝强调色、系统背景/分隔色和自动亮暗模式；
- 宽屏保持“来源侧栏—缩略图网格—检查器”三栏；
- 沿用 8px 网格间距、6–10px 连续圆角、次级文字和选中蓝色描边；
- 窄屏把来源变为横向筛选栏，检查器变为覆盖层，但信息层级和操作语义不变；
- 不使用外部字体、图标 CDN、前端框架或第三方运行时依赖。

## 验收门

1. Web 静态入口无需鉴权可加载，API 仍默认拒绝未配对访问；
2. Web 配对响应不向 JavaScript 返回 access / refresh token，并设置安全 Cookie；
3. Cookie 可访问 capabilities、来源、标签、资产、图片和 WebSocket；
4. Cookie 写请求拒绝非同源 Origin，合法同源标签写入成功；
5. access 过期后可通过 refresh Cookie 恢复；登出会清除 Cookie；
6. Mac Debug 构建和 Remote 定向测试通过；
7. 浏览器验证覆盖配对页、三栏图库、预览检查器、标签修改和响应式窄屏；
8. 自动化验证不读取 `/Volumes/HDD2` 受保护真实照片路径。

## 停止位置

本切片停止于单用户、单 Mac、现有 Cloudflare Tunnel 下的可用 Web Companion。暂不加入：

- Mac 离线可用、云端数据副本或推送唤醒；
- 多 Host、多租户、Cloudflare Access 或应用层端到端加密；
- Web 端来源管理、Photos 授权、训练配置、缓存清理、瘦身或永久删除；
- 原生 iOS 工程改造。
