# Mac Host + iOS Companion：已配对会话恢复打磨

## 状态

- 日期：2026-07-29
- 状态：Implementation delivered；实体 iPhone 交互确认待所有者回报
- 分支：`lgw/imageall-companion-productization`
- 工作树：`/Volumes/SSD1/ImageAll-Companion-Productization`
- 开工时主干：`ad636702 feat: toggle global thumbnail aspect ratio`
- Companion 前序：`52bcabf3 docs: record public Companion tunnel evidence`
- 汇合提交：`3ae10c89 merge: integrate iOS Companion product slice`
- 实现提交：`dcf11498 fix: clarify Mobile paired-session recovery`

## 问题与范围

实体 iPhone 公网配对已通过，但用户点“断开”后回到连接页时，界面仍把一次性扫码放在主要位置。
用户因此刷新并重扫二维码；若 Mac 没有活动 offer，Host 把内部枚举名 `noActiveOffer` 直接显示给
用户。实际上 Mobile 已在 Keychain 保存 refresh token，临时断开后不需要重新扫码。

本切片只完善这一条恢复路径：

1. 已配对状态提供“重新连接已配对 Host”，直接使用 Keychain refresh；
2. 连接态按钮改为“暂时断开”，明确不会删除配对；
3. 增加经确认的“清除此 iPhone 的配对”，先成功删除 Keychain refresh token，再清理本机
   Host 身份、公网 endpoint 和会话状态；
4. `noActiveOffer`、offer 过期/已使用和 refresh 授权失效改为可执行的中文恢复提示；
5. 明确本机清除不会冒充 Mac 端撤销；Mac 的设备记录仍由 Mac 设置页管理。

没有改变 Mac 写权威、Remote DTO、SQLite、PhotoKit、Cloudflare Tunnel 或公网信任边界。

## 自动化与构建证据

所有构建产物位于 `/Volumes/SSD1/.codex-build/`。Mac Remote 测试使用
`/tmp/ImageAll-Companion-Reconnect-Root` 作为隔离开发根，没有读取或写入 `/Volumes/HDD2`
及其受保护照片路径。

| 验证 | 结果 |
|---|---|
| `Packages/ImageAllRemoteProtocol` | 11 tests，0 failures |
| `Packages/ImageAllRemoteClient` | 37 tests，0 failures |
| Keychain 删除成功/失败路径 | 2 个新增测试通过；失败时保留原 refresh token |
| Mac Remote `build-for-testing` | 通过 |
| `RemoteHTTPServerTests` + `RemotePairingStoreTests` | 18 tests，0 failures |
| Mac Debug，未签名 | `xcodebuild` exit 0 |
| iOS Simulator Debug，未签名 | `xcodebuild` exit 0 |
| generic iOS Device Debug，Apple Development 签名 | `xcodebuild` exit 0 |
| `git diff --check` / `plutil -lint` | 通过 |

签名真机包已覆盖安装到连接的 iPhone 16 Pro Max，保留现有 App 数据和 Keychain 配对。没有使用
iPhone 镜像或自动操作手机界面。

## 实体 iPhone 手动确认

待所有者完成：

1. 打开 ImageAll Mobile，确认原有公网会话自动恢复；
2. 点击右上角“暂时断开”；
3. 确认连接页出现“重新连接已配对 Host”和“清除此 iPhone 的配对”；
4. 不清除配对，点击“重新连接已配对 Host”；
5. 确认不刷新二维码、不扫码即可返回图库/审核/任务页，并显示“公网 TLS”。

在收到所有者回报前，不把这五项写成已通过。

## 下一项建议

下一最小产品切片建议做 WebSocket 瞬断自动恢复与连接健康提示。当前 HTTP 会话可用 Keychain
恢复，但事件 socket 收到网络失败后会静默停止；公网 Companion 长时间前后台切换时可能继续
显示“已连接”而不再接收 Host 变化。

验收门：

1. WebSocket 意外断开后指数退避重连，用户主动“暂时断开”时不得重连；
2. access token 失效时先走一次 refresh，再恢复 HTTP 与 WebSocket；
3. UI 区分“已连接 / 正在重连 / Host 离线”，避免把旧数据当实时状态；
4. 覆盖主路径、主动断开和连续失败三个测试，并通过 Mac/iOS Debug 构建；
5. 真机切换 Wi-Fi/蜂窝网络后，无需重新扫码即可恢复事件流。
