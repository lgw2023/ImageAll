# Web Companion 来源管理控制台进展（2026-09-01）

## 目标与取舍

项目所有者要求 Web 与 Mac App 对齐功能和交互完整性，但不复制 Mac 外观。本轮先以 Mac
`RemoteSourceManagementCommandService` 为行为权威审计来源页，确认 Host 已支持 19 个来源动作，而 React
页面只暴露了少量通用入口。因此不扩展协议，直接补齐 Web 可达性、状态门控、任务反馈和安全确认。

视觉采用独立的“暗房操作控制台”：将高频同步、缓存维护和访问权限组织成三条命令轨道，来源卡片按类型和
状态建立清晰层级，低频与危险操作渐进展开。方向参考
[Adobe Lightroom Web 工作区](https://helpx.adobe.com/lightroom/web/get-set-up/learn-the-basics/tour-the-workspace.html)
的内容优先选择/筛选结构，以及 [Immich](https://immich.app/) 的响应式照片 Web 框架；只提炼信息层级与
交互规律，不复制品牌和组件。

## 已完成

1. 连接文件夹、连接 Photos、刷新全部、两种全局预热、批量重新授权、批量刷新文件夹修改权限均有明确入口；
2. 文件夹来源支持重新扫描、重新授权、刷新修改权限、两种预热和取消；Photos 来源支持同步、完整修复、
   重新绑定当前图库、读取/写入授权、打开系统隐私设置、两种预热和取消；移除来源对所有合法状态可达；
3. 操作严格按 Host 状态门控：活动、停用、需要授权、历史来源与位置不可用不会显示无效命令；
4. `awaitingMac`/`running` 请求锁定冲突写入，同时保留预热取消；界面显示 Host 权威阶段、来源进度和
   warmed/reused/failed/ineligible 计数；
5. 来源卡可直接进入 `/gallery?source=<id>`，范围可定址且不会产生修改请求；
6. 移除改为应用内 `alertdialog`：默认焦点在取消，Esc/取消零写入并恢复触发按钮焦点；确认后只发送精确
   `delete + sourceID`，Mac 仍执行原生第二次确认；Host 失败留在对话框内，可原位重试；
7. 桌面三轨控制台在 390 px 下折叠为大触点单列；成功消息使用 `status`，失败使用 `alert`；
8. Playwright 完整套件固定为 3 workers，避免 5 workers 的本机资源争用扭曲 10k 性能测量；性能阈值未放宽。

## TDD 与回归证据

- RED：完整修复、状态专属命令、批量授权、预热指标/取消、应用内删除、来源链接与错误 `alert` 均先由失败
  行为测试证明缺口；
- GREEN：每项测试分别通过后，再运行桌面与移动组合回归；
- Vitest：11 个文件、31 项全部通过；
- Playwright：138 项通过、4 项按浏览器项目配置跳过、0 失败；来源管理主路径覆盖桌面与 390 px 移动端，
  axe WCAG 2.1 A/AA 与控件无重叠检查通过；
- 10k 合成图库：首屏可交互 862 ms，DOM 704，卡片 30，选择反馈 p95 17.1 ms，灯箱 p95 108.5 ms，
  长任务 0，滚动锚点偏差 0 px；
- `format:check`、lint、typecheck、`git diff --check`：通过；
- `xcodebuild ... build-for-testing`：`TEST BUILD SUCCEEDED`；
- `asset-manifest.json` SHA-256：`67e54c9ff0184194db510aed69b139bd0648c197e67138b453776284b37b00b0`。

## 视觉证据

- `evidence/management/imageall-react-source-command-deck-chromium-desktop.png`
- `evidence/management/imageall-react-source-command-deck-chromium-mobile.png`

## 证据边界

所有自动化只使用合成 Host、合成来源和合成请求。没有读取、遍历或写入
`/Volumes/HDD2/Photos Library.photoslibrary` 或 HDD2 年份目录，也没有证明真实文件夹/Photos 授权、
iCloud、预热吞吐、磁盘变更或人工 VoiceOver 听读。
