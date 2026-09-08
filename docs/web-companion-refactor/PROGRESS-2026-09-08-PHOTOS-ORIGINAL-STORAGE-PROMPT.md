# Photos 原图副本位置前置提示纵切片

日期：2026-09-08
状态：`parity-proven`（合成 Host 范围）

## 对齐依据

只读参考 main 提交为 `3ee5f05cfdc110e173b5c8cbf4084bd594bf178a`；本功能的 Mac、业务门禁、
Remote 映射与 XCTest 来源提交为 `7499be1b40b2ed5534c3ea6e242a06accce201a2`。

Mac 在相同检测需要补全 Apple Photos 原图指纹、又没有已配置的原图副本位置时，会在 PhotoKit
请求与分析 Job 创建前停止，显示设置提示。Remote Host 已把同一业务错误投影为
`POST /v1/library-slimming/launch` 的 HTTP 409 `conflict`；此前 Web 只显示通用错误，没有完整操作指引。

## 差异与实现

1. **网页缺少界面或交互**：新增专用 `alertdialog`，明确当前分析未开始，以及应在 Mac App
   “设置 → 通用 → Photos 原图副本”选择位置并重启。Escape 和“暂不分析”都关闭对话框；由于异步
   请求期间触发按钮会被禁用，Web 显式保存按钮引用并在关闭后以 `preventScroll` 恢复焦点。
2. **Host 已有 API、网页尚未接入**：launch 只在 409、`code=conflict` 和 Host 完整约定文案同时
   匹配时进入专用路径；其他冲突保持既有错误处理。失败不写入成功消息、不选择 Job、不伪造任务。
3. **Host API 本身缺失**：完成本提示闭环没有缺失。现有错误只有通用 `conflict`，尚无更细的机器可读
   reason；当前对齐记录保留这一协议精度限制。
4. **浏览器限制与替代方案**：浏览器无法安全复刻 macOS `SettingsLink`，也不能用网页目录选择器
   代表 Host 的 security-scoped bookmark。Web 因此只提供准确的 Mac 操作路径，不提供伪设置入口。

视觉沿用现有 Web 删除/维护对话框的空间、排版和 modal 行为，仅把危险红色替换为已有 warning token；
没有复制 SwiftUI 外观，也没有改变 Host 权威业务语义。

## 验证证据

- 主路径：现有目录分析成功提交，Host 接受 120 项范围并出现运行中 Job。
- 必要失败路径：首次 launch 返回与 Remote Facade 相同的 409 后显示专用提示；零成功态，关闭后焦点
  返回“开始分析”，第二次提交成功。桌面与 390px 触屏均验证 axe A/AA 和无横向溢出。
- 相关回归：图库精简 Playwright 桌面+移动 16/16；Vitest 35/35；`test:dev-sandbox` 的图库、会话内
  mutation、刷新、预览、未知 API 拒绝与外部 Host 阻断通过；typecheck、lint、format 与生产构建通过。
- 截图：
  - `evidence/slimming/imageall-react-photos-original-storage-prompt-chromium-desktop.png`
  - `evidence/slimming/imageall-react-photos-original-storage-prompt-chromium-mobile.png`

全部自动化使用合成 JSON、合成媒体和隔离 Chromium；没有启动真实 Swift Host，没有读取或遍历
`/Volumes/HDD2`，也没有访问日常 App、数据库、设置、配对信息或 8787/8788 端口。

## 尚待真实后端验证与剩余差异

- 待满足 ADR-072 的应用身份、数据目录、设置/钥匙串、端口和 DerivedData 全隔离后，验证真实开发 Host
  的 409 能在 PhotoKit 请求与 Job 创建前返回，并验证完成 Mac 设置、重启后的同页重试成功。
- Web 不能直接打开 Mac 设置或选择 Host 目录；这是平台边界，不以降级前端假功能补齐。
- 若后续协议新增专用 machine-readable reason，应改用 reason 判定并保留旧 Host 文案匹配兼容分支。
