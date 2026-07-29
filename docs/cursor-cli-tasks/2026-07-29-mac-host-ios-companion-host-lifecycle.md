# Mac Host + iOS Companion：Host 即时生命周期打磨

## 状态

- 日期：2026-07-29
- 状态：Implementation delivered；新构建的实体 Mac UI 即时开关确认待所有者回报
- 分支：`lgw/imageall-companion-productization`
- 工作树：`/Volumes/SSD1/ImageAll-Companion-Productization`
- 开工时主干：`088bf4f8 fix: recover stalled slimming analysis`
- 前序 Companion：`8aad37e1 docs: record Companion session recovery evidence`
- 主干汇合：`edbe5ee2 Merge branch 'main' into lgw/imageall-companion-productization`
- 实现提交：`a0e50859 fix: apply mobile Host settings immediately`

## 问题与决策

旧实现只在 `CompositionRoot` 装配时读取一次 `imageall.remoteHost.enabled`。设置页的开关只写
`UserDefaults`，因此用户在已打开的 App 中启用 Host 后仍会看到“未运行”，并被要求重启 App。
公网 Base URL 也有同样问题。

本切片把设置改为真实的当前进程生命周期控制：

1. 新安装默认启用移动 Host；用户显式关闭后继续尊重该选择；
2. “启用移动 Host”打开时立即启动当前 App 内嵌的 `RemoteHTTPServer`，关闭时立即停止；
3. 开关操作优先于 `IMAGEALL_REMOTE_HOST` 开发环境默认值，避免 UI 显示与实际选择相反；
4. Host 保留已装配的窄 `RemoteCatalogServing` / `PersonalizationReviewPort`，切换时不经过
   `LibraryWorkspaceModel`；
5. 保存或清空公网 Base URL 后立即重载 Host，废弃旧短时 offer；新二维码使用新入口；
6. 设置页在 App 启动后的两秒窗口内收敛运行状态，避免 Host 初始化期间短暂误报；
7. 快速重载使用 generation 防止旧的异步启动结果覆盖更新的开关操作。

ADR-044 与完整路径的 `docs/ADR-047-MAC-HOST-CLOUDFLARE-PUBLIC-TUNNEL.md` 已同步改为
“默认启用 + 即时开关”。

## 进程边界

- `RemoteHTTPServer` 仍内嵌在 ImageAll Mac App 进程中；App 退出时 Host 随之退出。
- `cloudflared` 仍是独立 LaunchAgent，负责把
  `https://imageall.ultrahardcore.net` 转发到本机 `https://127.0.0.1:8787`。
- 因此 Tunnel 进程运行不代表 Host 正常：若 ImageAll 未监听 8787，公网入口会返回 502。

交付前只读现场检查显示：用户当前 Xcode 旧构建仍在运行，但 8787 没有监听，公网返回 502；
`cloudflared` LaunchAgent 为 running。该旧进程不包含本提交，需要重新编译运行新构建一次。
从新构建开始，设置开关不再要求重启。

## 自动化与构建证据

测试和构建产物全部位于 `/tmp/ImageAll-Companion-Lifecycle-*`。没有运行需要真实图库的测试，
没有读取或写入 `/Volumes/HDD2` 及其受保护照片路径。

| 验证 | 结果 |
|---|---|
| `Packages/ImageAllRemoteProtocol` | 11 tests，0 failures |
| `Packages/ImageAllRemoteClient` | 37 tests，0 failures |
| 新增默认值 / 用户开关优先级测试 | 2 tests，0 failures |
| `RemoteHTTPServerTests` + `RemotePairingStoreTests` | 20 tests，0 failures |
| Mac Debug，未签名 | `xcodebuild` exit 0 |
| iOS Simulator Debug，未签名 | `xcodebuild` exit 0 |
| generic iOS Device Debug，未签名 | `xcodebuild` exit 0 |
| `git diff --check` | 通过 |

iOS 第一次构建误用了 Mac 工程中不存在的 `ImageAllMobile` scheme，命令在解析阶段退出；改用
独立的 `ImageAllMobile.xcodeproj` 后，模拟器和设备 Debug 构建均通过。这不是代码失败。

## 实体 Mac 手动确认

待所有者使用新构建完成：

1. 停止当前旧 Xcode App，切到本分支并重新编译运行一次；
2. 打开“设置 > 移动 Host”，确认开关默认打开，运行状态在约两秒内变为“运行中”；
3. 取消勾选，确认无需退出 App，状态立即变为“未运行”；
4. 再次勾选，确认无需退出 App，状态立即变为“运行中”；
5. 确认公网入口为 `https://imageall.ultrahardcore.net`，点击“开始配对”；
6. 确认新二维码显示“公网入口”，iPhone 扫码后使用公网 443，而不是局域网 8787。

在收到所有者回报前，不把以上实体 UI 项写成已通过。

## 停止位置

本切片停止于 Host 默认启用、当前进程即时启停、公网 Base URL 即时重载与对应验证。没有进入
多租户 Relay、后台守护、推送唤醒或应用层 E2E Relay。
