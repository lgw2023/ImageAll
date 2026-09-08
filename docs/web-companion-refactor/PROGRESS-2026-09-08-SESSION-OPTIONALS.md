# 登录响应可选字段解码修复

## 根因与参考

用户报告账户登录显示“服务器数据与当前 Web 版本不兼容”。开发基线为 `954e4bcd`，
只读 main 为 `c64ade5ef1e9d9a350df539fb74bb716abea0eac`；其新增自动训练功能，登录契约无差异。

`RemoteHTTPServer.swift` 的账户登录成功响应设置 `deviceID: nil`；
`RemoteWebCompanion.swift` 的 `StatusResponse: Codable` 使用 Swift 合成编码，nil 字段省略。
原 Web schema 的 `.nullable()` 要求键存在，导致合法 200 响应仍在 `deviceID` 解码处失败。
配对模式的 `username: nil` 同样受影响。原合成 fixture 手写 null，未覆盖真实编码形态。

从当前 Host 源文件抽取原样 `StatusResponse` 声明，以 Foundation JSONEncoder 在本 worktree
独立编译执行（编译缓存位于本 worktree `.build/session-contract-module-cache`），得到：

```json
{"authMode":"account","authenticated":true,"username":"reader"}
{"authMode":"pairedDevice","authenticated":true,"deviceID":"7DD77E6B-8C95-4F5A-90E7-CBC61F3E24C4"}
```

## 修复与验证

- `deviceID`、`authMode`、`username` 使用现有 `nullishToNull`，兼容省略与显式 null；字段存在时
  仍校验 UUID、枚举和字符串，不改 Host 鉴权、凭据存储或登录请求。
- 合成会话与完整登录 E2E 移除 Host 不会编码的 null。
- 新增省略字段契约用例在修复前于 `deviceID` 得到 `invalid_type`，修复后通过。
- Vitest 36/36、typecheck、lint、format:check、生产构建通过。
- 桌面/移动端登录 E2E 2/2：配对进入图库 → 退出 → 账户 401 保持登录页 → 再提交以省略字段的
  200 响应进入图库；保留凭据不持久化断言。

## 交付边界

修复未修改 Swift 或启动真实 Host，未读取用户密码、日常图库、数据库或配对数据。

## 授权发布（2026-09-08）

用户退出 App 后明确授权发布及同步代码主干，并要求自行重启。
开发分支先合入 main `c64ade5e`，保留其自动标签训练改动；网页分支已有的隔离开发入口、
Photos 原片目录提示和本次登录修复一并集成本地 main，不 push。

- 集成后重新通过 36 项单元测试、typecheck、生产构建及桌面/移动登录 E2E 2/2。
- 在开发 worktree `.build/web-release-QnERXAqR` 复制日常 App，先验证 159 个文件/符号链接
  与原副本一致，只替换 `Contents/Resources/WebCompanionV2`，不重新构建原生 Host。
- 使用原 Apple Development 签名身份重新签名，保留 identifier、entitlements、requirements、
  flags、runtime；发布前后 `codesign --verify --deep --strict` 均通过。
- 已发布到 `/Volumes/SSD1/ImageAll-Daily/ImageAll.app`；网页资源 SHA-256 清单与本次构建一致，
  其他变化仅限应用签名及可执行文件签名。
- 完整旧版保留在 `/Volumes/SSD1/ImageAll-Daily/ImageAll-before-web-login-fix-20260908-1510.app`。
  未自动启动任何 App；实际 Host 登录仍待用户重启后人工验证。代码主干集成不代表重新发布
  main 的原生二进制，本次仅发布网页修复资源。
