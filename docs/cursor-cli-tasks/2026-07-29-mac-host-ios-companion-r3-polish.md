# 任务：mac-host-ios-companion-r3-polish

## 状态

- 任务 ID：`mac-host-ios-companion-r3-polish`
- 状态：In Verification（修复版地址解析通过；macOS 入站防火墙待所有者授权调整）
- 权威决策：
  - `docs/ADR-043-MAC-HOST-IOS-COMPANION.md`
  - `docs/ADR-044-MAC-HOST-COMPANION-R3.md`
- 开工基线：`51eec706170ccf0a2b1f99494c45aa7f9559f2a3`
- 隔离分支：`lgw/imageall-mobile-r3-polish`
- 实现提交：`17237f2f`
- 身份绑定加固提交：`38d9e6a8`
- Keychain 凭据加固提交：`91a3cc5a`
- 真机配对路径加固提交：`c9eda11c`
- 实施身份：Codex；实现 `feat(codex):` / `fix(codex):`；文档 `docs(codex):`

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

## 已配对 Host 身份绑定加固

真机 smoke 尚未具备设备条件，但静态复核发现两个可独立闭环的会话缺口：

1. Mobile 原先只保存 Host 地址，没有保存配对返回的 `hostID`。Mac 的局域网地址变化后，
   已配对会话无法根据 Bonjour 中的稳定身份找回新地址。
2. pairing/refresh 请求虽然由既有证书指纹固定的 TLS 通道保护，但客户端会直接保存响应 DTO
   中的新指纹；响应若与原信任锚不一致，不应静默迁移信任。

提交 `38d9e6a8` 完成以下加固：

- 配对成功后持久化 `hostID`，断开状态收到 Bonjour 更新时仅按该稳定身份更新 Host 地址和端口；
- 扫码匹配优先且严格使用 `hostID`，只有旧 Host 未广播身份时才允许同名兼容回退；
- pairing 与 refresh 响应在落盘前校验 Host ID、TLS 模式、证书 SHA-256 指纹和端口；
- TLS 指纹只接受 64 位 ASCII 十六进制，或严格的 32 组冒号分隔字节，不再忽略任意夹杂字符；
- 旧 Mobile 会话没有持久化 `hostID` 时仍可用原指纹完成一次 refresh，成功后自动补存身份。

本加固不改 Remote DTO，不允许远端替代 Mac 写权威，也不改变 R3/R4 边界。

## Mobile 会话凭据 Keychain 加固

静态复核发现 Mobile 把配对返回的短期 `accessToken` 与可撤销 `refreshToken` 都写入
`UserDefaults`。提交 `91a3cc5a` 将凭据边界收紧为：

- `refreshToken` 作为 non-synchronizable generic-password item 写入 iOS Keychain，
  accessibility 为 `whenUnlockedThisDeviceOnly`，不经 iCloud Keychain 同步；
- `accessToken` 只保留在当前进程内存，不再持久化；断开连接时清空；
- Host 地址、端口、`deviceID`、`hostID`、TLS 模式与证书指纹仍作为非秘密连接元数据保存在
  `UserDefaults`；
- 启动时若发现旧 `refreshToken`，先确认 Keychain 写入成功，再删除旧 access/refresh 值；
- Keychain 已有 refresh credential 时，以安全存储为准并清理陈旧偏好副本；
- 旧值为空或 Keychain 写入失败时，不删除旧偏好，也不拿旧 refresh token 请求 Host 轮换；
- 新配对完成后直接使用刚签发的短期 access token 建立固定证书的 TLS 会话，不再为了连接立刻额外
  refresh 一次；
- 新配对或正常 refresh 已从 Host 收到新 token、但 Keychain 更新失败时，Mobile 仅把新 token
  保留在当前内存会话，删除可能已经失效的 Keychain 旧值，并明确提示重启后需要重新配对。

Keychain 存取和旧值迁移封装在 `ImageAllRemoteClient` 的小接口后；自动化测试只替换系统安全存储
边界，不读取真实 Keychain，也不记录任何真实 token。

## 真机扫码发现与隔离 Host 加固

物理 iPhone 已完成开发者信任、签名安装、App 启动和相机扫码。第一次扫码使用的是
`35f4eda8` Mobile：二维码被正确读取，但 Mobile 未发现对应 Bonjour Host 时沿用了连接表单
默认值 `127.0.0.1`，最终向 iPhone 自身发起连接并显示 `Could not connect to the server.`。
该结果证明相机/二维码解析主路径可用，但不能算配对或 TLS 通过。

`c9eda11c` 对应的签名 iOS Device Debug 构建随后已通过 `devicectl` 安装并成功启动；二次扫码
需要设备拔线并锁屏后由 iPhone 镜像继续。

二次扫码已确认 Host 表单保持为 Mac 局域网地址，不再回落 `127.0.0.1`；二维码 JSON 被正确
填入，但 HTTPS pairing 返回超时。Mac 本机访问 loopback `:8787` 立即得到预期 `401`，进程监听
`*:8787`，而访问本机局域网地址的 TLS 握手失败。只读系统检查显示 macOS Application Firewall
处于“阻止所有非必要传入连接”（state 2），且已有 ImageAll 规则为阻止传入。调整系统防火墙属于
安全敏感设置，本轮停止在明确授权门前，没有自行修改。

提交 `c9eda11c` 做了以下收敛：

- 扫码优先使用已发现的精确 `hostID`；没有匹配发现结果时只接受用户显式输入的非回环地址；
- 默认值为空、`localhost`、IPv6 loopback 或任意 `127.*` 时，在发网络请求前给出局域网地址提示；
- 手动 Host/端口立即保存为非秘密 endpoint hint，App 重启后不再回到错误默认值；
- 连接页明确解释 `127.0.0.1` 代表当前 iPhone，并增加一次性读取剪贴板 JSON 的回退按钮；
- macOS 26.5 的 Bonjour 测试改为从 `txtRecordObject` 验证 Host ID，避免旧 Data getter 对新对象
  initializer 返回 `nil` 的测试假失败。

为避免人工 Host smoke 误开生产 catalog，Debug 版增加
`IMAGEALL_DEVELOPMENT_ROOT`：仅接受非空绝对路径且拒绝 `/`；变量存在但非法时 fail closed，
不会回退生产 `Application Support`。Release 构建不接受此开发覆盖。

### 本地数据边界事件

首次启动人工 Host 时只设置了 `CFFIXED_USER_HOME`，App sandbox 仍解析到生产 catalog，并打开了
生产数据库和受保护卷来源的文件描述符。发现后在配对、标签、审核、任务或文件写入发生前立即停止；
该次启动不计入测试证据。随后为确认进程状态误执行了一次对受保护卷的递归 `lsof +D`，这同样违反
了只读人工验证边界。没有观察到源照片、sidecar、配对记录或远端命令写入，但“本轮完全未访问
受保护卷”这一表述不成立。

之后所有 Host smoke 均使用空的隔离 catalog；进程级文件描述符检查确认没有生产 catalog 或受保护
卷句柄。自动化测试没有读取受保护真实照片。

### 公网出口 / cloudflared 结论

只以脱敏方式核对了 `~/.cloudflared/config.yml` 的结构，没有记录域名、Tunnel ID、凭据路径或
其他秘密，也没有修改配置。现有 ingress 是 HTTP origin 路由，Cloudflare 会在边缘终止 TLS；
Mobile 看到的是边缘证书，而 R3 二维码固定的是 Mac Host 自签名证书，因此直接套用会触发指纹
不一致。该配置可作为 R4 新 ADR 的部署输入，但不能静默接入 R3。若要异地访问，仍需先定义端到端
信任、Mac 出站隧道和 Relay 验收门。Cloudflare 的
[Published application protocols](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/protocols/)
也明确区分 HTTP/HTTPS 代理与需要客户端 `cloudflared` 的非 HTTP TCP 路径。

## 自动化与构建证据

所有仓库命令均在隔离 worktree 执行；构建产物写入外部隔离的
`/Volumes/SSD1/.codex-build` 或 `/tmp`。自动化验证没有启动 Mac 生产 App。

| 验证 | 结果 |
|---|---|
| `Packages/ImageAllRemoteProtocol`：`swift test -q` | 9 tests，0 failures |
| `Packages/ImageAllRemoteClient`：`swift test -q` | 29 tests，0 failures |
| Mobile Debug，generic iOS Simulator | `BUILD SUCCEEDED` |
| Mobile Debug，generic iOS Device/arm64 | `BUILD SUCCEEDED` |
| Mobile Debug，签名 generic iOS Device/arm64 | `BUILD SUCCEEDED` |
| Mac Debug，macOS | `BUILD SUCCEEDED` |
| Remote 五组测试 `build-for-testing` | 成功编译 |
| `CompositionRootTests` + 四组无 Keychain Remote 裸 bundle 定向执行 | 39 tests，0 failures |
| Mobile Simulator 启动与连接页视觉 smoke | 通过；未崩溃，扫码回退与连接表单可见 |
| Mobile Simulator 合成旧凭据迁移 | 通过；Keychain 成功提示、access 输入清空、App 偏好 plist 无 token |
| 物理 iPhone 签名安装、启动与相机扫码 | 修复版安装/启动/QR/地址解析通过；pairing 被入站防火墙阻断 |
| `plutil -lint ImageAllMobile/Info.plist` | OK |
| `git diff --check` / cached diff check | 通过 |

Remote 定向编译包含：

- `RemoteCatalogFacadeTests`
- `RemoteHTTPServerTests`
- `RemoteHostIdentityTests`
- `RemoteIdempotencyStoreTests`
- `RemotePairingStoreTests`

身份绑定新增的 10 项 Client 测试覆盖：

- 二维码指纹严格格式与冒号分隔兼容；
- pairing/refresh Host ID 与 TLS 指纹不漂移；
- 旧会话缺失已存 Host ID 的一次性迁移；
- Bonjour 精确身份优先、拒绝同名不同身份、旧 Host 同名回退。

Keychain 新增的 4 项 Client 测试覆盖：

- 旧 refresh token 成功迁入安全存储后才删除旧值；
- 空白旧值拒绝迁移且保留原值；
- 安全存储写入失败时保留旧值；
- Keychain 已有值优先于陈旧偏好值。

模拟器运行 smoke 使用本轮创建的可丢弃 iPhone 模拟器与合成 token。第一轮刻意使用
`CODE_SIGNING_ALLOWED=NO` 的构建，系统拒绝 Keychain，Mobile 显示缺失 entitlement 错误且保留
旧值，验证了失败保护路径。随后使用正常签名的 Simulator Debug 构建，Migration 状态显示成功，
access token 输入已清空，App 数据容器内的 `Library/Preferences/com.gwlee.ImageAllMobile.plist`
为空。临时模拟器在取证后已关机并删除。

本轮曾先以 Mac 工程名调用 Mobile scheme，Xcode 在方案解析阶段返回
“不包含 `ImageAllMobile` scheme”；更正为独立的 `ImageAllMobile.xcodeproj` 后，模拟器与
设备架构 Debug 构建均成功。该误调用未启动 App、测试宿主或数据访问。

Keychain 加固的第一次聚合验证命令曾在仓库根目录直接执行 `swift test`，SwiftPM 因根目录没有
`Package.swift` 在包发现阶段退出；随后分别进入两个 Package 目录重跑，得到上表 27/27 与
9/9 的最终结果。该误调用没有启动 App、测试宿主或数据访问。

未执行 Mac `xcodebuild test`：`ImageAllTests` 当前配置了生产 `ImageAll.app` 作为
`TEST_HOST`。`docs/LOCAL-TEST-DATA-SAFETY.md` 已记录，在受保护 Photos Library 所在卷挂载时，
即使只选 Remote 测试，启动该宿主也可能在测试方法前初始化系统 Photos store。本次用
`build-for-testing` 验证 Remote 测试与生产代码可编译；外部构建产物补测试 bundle rpath 并
临时 ad-hoc 重签后，直接执行 `CompositionRootTests`、`RemoteCatalogFacadeTests`、
`RemoteHTTPServerTests`、`RemoteIdempotencyStoreTests` 和 `RemotePairingStoreTests`，
得到 39/39。`RemoteHostIdentityTests` 明确依赖签名 App 的 Data Protection Keychain；
裸 `xctest` 缺少 App keychain access group 时按设计退回 cleartext，不能把该环境失败算成产品
回归。签名隔离 Host 的人工运行已生成可用 TLS 身份；待提供不会初始化 Photos store 的隔离
test host 后，再补该测试的自动化执行结果。

## 真机 TLS / 配对 smoke 清单

2026-07-29 已接入 iPhone 16 Pro Max（iOS 26.5.2）。签名安装、启动、相机授权和二维码读取通过；
旧版因未发现 Bonjour Host 而误用 `127.0.0.1`，配对/TLS 及连接后功能尚未通过。修复版已签名
构建、安装并启动；二次扫码地址解析已通过，pairing 当前被 macOS 入站防火墙阻断。

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

- iPhone 型号 / iOS 版本：iPhone 16 Pro Max / iOS 26.5.2
- Mac build commit：`c9eda11c` 对应工作树构建；隔离空 catalog
- Mobile build commit：旧版扫码 `35f4eda8`；已安装修复版 `c9eda11c`
- Host ID：仅记录首尾各 4 位；
- TLS 指纹：仅记录首尾各 4 位；
- 相机 / QR / pairing Host 解析：PASS / PASS / PASS
- 配对 / TLS / preview / review / job / WS：BLOCKED（macOS 防火墙 state 2）
- 撤销后 refresh：PASS 或失败码；
- 是否访问受保护真实数据：自动化否；首次错误 Host 启动和递归检查发生边界事件，见上文
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
- refresh token 只进入本机、设备解锁时可读的非同步 Keychain item；
- access token 不再持久化，旧 UserDefaults secret 仅在 Keychain 迁移失败时原样保留；
- 审核/标签写操作继续使用随机 `operationID` 和 Host 持久幂等；
- 自动化测试使用纯 DTO/Mock transport/构建验证，没有读取受保护真实照片；
- 首次人工 Host 启动与随后递归检查发生边界事件；已完整记录，后续使用空隔离 catalog；
- 未启动 Mac 生产测试宿主。

### 重点复审文件

- `ImageAllMobile/App/RemoteCompanionModel.swift`
- `ImageAllMobile/App/RemoteCompanionViews.swift`
- `Packages/ImageAllRemoteClient/Sources/ImageAllRemoteClient/RemoteSessionCredentialVault.swift`
- `Packages/ImageAllRemoteClient/Sources/ImageAllRemoteClient/RemotePairingPayloadDecoder.swift`
- `Packages/ImageAllRemoteClient/Sources/ImageAllRemoteClient/RemoteHostBrowser.swift`
- `Packages/ImageAllRemoteProtocol/Sources/ImageAllRemoteProtocol/RemoteBonjour.swift`
- `ImageAll/Infrastructure/Remote/RemoteHTTPServer.swift`

### 已知剩余项

1. 物理 iPhone 真机 smoke 已推进到 pairing 网络连接；需所有者授权临时关闭“阻止所有传入”
   并允许隔离 ImageAll Debug App 后，完成配对/TLS、preview/review/job/WS、Keychain 跨重启
   持久性与撤销复测。
2. `RemoteHostIdentityTests` 已编译，但裸 bundle 没有签名 App Keychain 权限；需无 Photos 初始化的
   隔离 test host 后补自动化执行证据。
3. `~/.cloudflared/config.yml` 仅作为 R4 设计输入；现有 HTTP ingress 与 R3 Host 证书固定不兼容。
4. 本切片停止于 R3 Mobile 打磨；不自动进入 R4 Relay。
