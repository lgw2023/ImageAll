# 任务：mac-host-ios-companion-r3-polish

## 状态

- 任务 ID：`mac-host-ios-companion-r3-polish`
- 状态：Delivered（真机人工 smoke 待有 iPhone 接入后执行）
- 权威决策：
  - `docs/ADR-043-MAC-HOST-IOS-COMPANION.md`
  - `docs/ADR-044-MAC-HOST-COMPANION-R3.md`
- 开工基线：`51eec706170ccf0a2b1f99494c45aa7f9559f2a3`
- 隔离分支：`lgw/imageall-mobile-r3-polish`
- 实现提交：`17237f2f`
- 实施身份：Codex；实现 `feat(codex):`；文档 `docs(codex):`

## 并行工作区边界

开工时主 worktree `/Volumes/SSD1/ImageAll` 有另一会话约 50 个未提交的 Library、
Personalization、Migration、媒体与规格文件。该 worktree 保持在 `main`，本任务从其已提交
HEAD `51eec706` 建立独立 worktree `/Volumes/SSD1/ImageAll-R3-Polish`：

- 未 reset、stash、clean 或暂存主 worktree 草稿；
- 本任务未修改并行会话正在编辑的文件；
- 未 push；未改写 `main` 或远端历史。

## 交付范围

### Mobile 用户闭环

1. 连接页增加原生相机 QR 扫描；模拟器/不支持相机设备保留粘贴 JSON 回退。
2. 配对载荷在发网络请求前验证：
   - JSON 结构；
   - 过期时间；
   - 协议版本；
   - 端口；
   - 一次性 token；
   - TLS 证书指纹。
3. 图库页把“打开预览”和“批量选择”拆成独立动作：
   - 预览加载 Host preview/thumbnail 与 inspector detail；
   - 展示来源、媒体、尺寸和标签状态；
   - 可对当前标签执行 accept/reject/clear。
4. 新增审核页：
   - 标签/来源筛选；
   - 分页与下拉刷新；
   - 独立缩略图缓存；
   - 单项预览；
   - 单项或批量 accept/reject/clear。
5. 新增任务页：
   - 状态与确定/不确定总量进度；
   - 仅显示 Host 返回的可用 pause/resume/cancel；
   - 操作后重新读取 Host 权威状态。
6. WebSocket 刷新修复：
   - `reviewChanged` 刷新审核队列；
   - `jobsChanged` 刷新任务；
   - source/asset/tag 变化同步刷新受影响视图。

### 扫码地址解析修复

ADR-044 的二维码按安全边界只带 `hostID`、端口提示、一次性 token、TLS 指纹等信息，不带
长期 bearer，也不把局域网 IP 固化到二维码。R3 原实现的 Bonjour TXT 只广播协议版本，
因此扫码后无法可靠把 `hostID` 映射到已发现的地址。

本次保持二维码安全边界不变，给 Bonjour TXT 增加可选 `hostID`：

- Mac Host 广播自己的持久 `hostID`；
- Mobile discovery 投影该字段；
- 扫码后优先以 `hostID` 选择对应 Host；
- 后续 HTTPS 仍必须通过二维码证书指纹固定校验；
- 旧 Host 没有该字段时，保留已选择 Host/同名发现结果的兼容路径。

该字段为向后兼容的可选 TXT 元数据，不改变 HTTP DTO，不同步数据库，也不把
`LibraryWorkspaceModel` 作为网络入口。

## 自动化与构建证据

所有命令均在隔离 worktree 执行；构建产物写入 `/tmp`，没有启动 Mac 生产 App。

| 验证 | 结果 |
|---|---|
| `Packages/ImageAllRemoteProtocol`：`swift test -q` | 9 tests，0 failures |
| `Packages/ImageAllRemoteClient`：`swift test -q` | 13 tests，0 failures |
| Mobile Debug，generic iOS Simulator | `BUILD SUCCEEDED` |
| Mobile Debug，generic iOS Device/arm64 | `BUILD SUCCEEDED` |
| Mac Debug，macOS | `BUILD SUCCEEDED` |
| Remote 五组测试 `build-for-testing` | 成功编译 |
| Mobile Simulator 启动与连接页视觉 smoke | 通过；未崩溃，扫码回退与连接表单可见 |
| `plutil -lint ImageAllMobile/Info.plist` | OK |
| `git diff --check` / cached diff check | 通过 |

Remote 定向编译包含：

- `RemoteCatalogFacadeTests`
- `RemoteHTTPServerTests`
- `RemoteHostIdentityTests`
- `RemoteIdempotencyStoreTests`
- `RemotePairingStoreTests`

未执行 Mac `xcodebuild test`：`ImageAllTests` 当前配置了生产 `ImageAll.app` 作为
`TEST_HOST`。`docs/LOCAL-TEST-DATA-SAFETY.md` 已记录，在受保护 Photos Library 所在卷挂载时，
即使只选 Remote 测试，启动该宿主也可能在测试方法前初始化系统 Photos store。本次用
`build-for-testing` 验证 Remote 测试与生产代码可编译，并用两个不启动生产 Host 的 Swift
Package 套件执行行为测试；待提供隔离 test host，或所有者针对一次具体宿主启动给出现场授权后，
再补 Remote Xcode 执行结果。

## 真机 TLS / 配对 smoke 清单

2026-07-29 执行 `xcrun xctrace list devices` 时只有本机 Mac 和模拟器，没有物理 iPhone；
因此以下清单已准备但未伪报为执行成功。

### 前置条件

- 一台已解锁、信任此 Mac 的 iOS 18+ iPhone；
- Mac 与 iPhone 在同一局域网；
- 使用合成/可丢弃 catalog，或不包含受保护真实照片的来源；
- Mac Debug Host 已由用户开关启用并重启；
- Mac 设置页显示非空 Host ID、TLS=是、64 位证书 SHA-256 指纹；
- iPhone 允许 ImageAll Mobile 使用相机与局域网。

### 主路径

1. Mac 设置 → 移动辅助 Host → 开始配对，确认出现约 5 分钟有效的二维码。
2. iPhone 打开 ImageAll Mobile，确认 Bonjour 列表出现对应 Mac。
3. 点击“扫描 Mac 配对二维码”，不复制长期 token、不手输指纹。
4. 扫码后确认 Mobile 自动匹配同一 `hostID`，显示“配对成功”及“已连接 … · TLS”。
5. 在 Mac 撤销该设备前，验证：
   - 图库分页和缩略图；
   - 点图片打开 preview/inspector；
   - 当前标签 accept/reject/clear；
   - 审核队列筛选、分页、预览与决定；
   - 任务进度及 Host 明示的一个可用动作；
   - Mac 侧变化经 WebSocket 使对应 Mobile 页面刷新。
6. Mac 撤销设备，确认旧 refresh token 不能建立新会话。
7. Mac 生成新二维码，确认 Mobile 可重新配对。

### 失败路径

- 扫描已过期二维码：Mobile 在发网络请求前提示重新生成；
- 篡改协议版本：提示协议不兼容；
- 删除/篡改 TLS 指纹：本地拒绝或 TLS challenge 失败；
- 关闭相机权限：扫码不可用，粘贴 JSON 回退仍可见；
- 关闭局域网权限/Host 离线：配对失败但不保存伪成功状态；
- Host 不声明 review/jobs capability：对应页面显示不支持，不发送操作。

### 现场证据模板

只记录聚合与非敏感证据：

- iPhone 型号 / iOS 版本：
- Mac build commit：
- Mobile build commit：
- Host ID：仅记录首尾各 4 位；
- TLS 指纹：仅记录首尾各 4 位；
- 配对 / TLS / preview / review / job / WS：PASS 或失败码；
- 撤销后 refresh：PASS 或失败码；
- 是否访问受保护真实数据：否；
- 是否发生源端写入：否；

不得把 pairing token、access/refresh token、完整指纹、照片内容、逐项路径或 Photos local
identifier 写入证据。

## 复审材料

### 架构合规

- Mac 仍是唯一 GRDB、PhotoKit、Job、标签与审核写权威；
- Mobile 只发送命令并消费 DTO；
- 网络入口仍是 `RemoteCatalogFacade` / `RemoteHTTPServer`，未经过
  `LibraryWorkspaceModel`；
- 未拆分 `LibraryWorkspacePort`；
- 未同步 SQLite，未实现 WebRTC 或 Relay；
- R4 未启动。

### 安全与隐私

- QR 不含长期 bearer；
- TLS 指纹在网络请求前做格式校验，连接时继续固定证书；
- 审核/标签写操作继续使用随机 `operationID` 和 Host 持久幂等；
- 测试使用纯 DTO/Mock transport/构建验证；
- 未访问 `/Volumes/HDD2`，未读取或写入受保护真实照片；
- 未启动 Mac 生产测试宿主。

### 重点复审文件

- `ImageAllMobile/App/RemoteCompanionModel.swift`
- `ImageAllMobile/App/RemoteCompanionViews.swift`
- `Packages/ImageAllRemoteClient/Sources/ImageAllRemoteClient/RemotePairingPayloadDecoder.swift`
- `Packages/ImageAllRemoteClient/Sources/ImageAllRemoteClient/RemoteHostBrowser.swift`
- `Packages/ImageAllRemoteProtocol/Sources/ImageAllRemoteProtocol/RemoteBonjour.swift`
- `ImageAll/Infrastructure/Remote/RemoteHTTPServer.swift`

### 已知剩余项

1. 物理 iPhone 未接入，真机相机、局域网权限与 TLS 配对主路径仍需按清单现场执行。
2. Mac Remote Xcode 测试已编译但未启动生产 test host；需隔离宿主或一次具体授权后补执行证据。
3. 本切片停止于 R3 Mobile 打磨；不自动进入 R4 Relay。
