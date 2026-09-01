# 普通图库删除闭环进展（2026-09-01）

## 本轮结论

普通图库删除已完成一个可验证的 Web 纵切片：单图查看与批量选择都先经过 Web 应用内破坏性确认，再向 Mac Host 提交冻结且精确的资产范围；浏览器只报告“已进入 Mac 删除确认队列”，不声称已经删除。

本轮同时修复了一处真实契约错误。旧批量入口显示“移至回收区”，并提交 `gallerySelection + recoverableRecycle`；真实 Host 对普通图库选择只接受 `releaseSourceSpace`，因此旧流程会被拒绝，而合成 Host 曾错误地放行它。现在 Web 与合成 Host 都服从真实 Host 约束。

## 产品与安全边界

- 文件夹来源的原片可能被永久删除；Apple Photos 资产进入系统“最近删除”。
- 收藏资产仍由 Host 保护；Web 不自行复制保护规则或乐观推断结果。
- Web 确认后仍保留 Mac 端第二次确认，最终破坏性动作由 Host 权威执行。
- 本轮没有改变协议，只纠正调用方 payload 并补齐交互。
- 自动化只使用合成资产，没有读取、遍历或写入 `/Volumes/HDD2/Photos Library.photoslibrary` 及 HDD2 年份目录，也没有对任何真实照片或文件执行删除。

## 用户可见行为

- 单图查看新增“删除当前照片”，批量选择栏改为“删除所选项目”。
- 两个入口共用 `role="alertdialog"` 的应用内确认，默认焦点停在“取消”。
- 取消和 `Esc` 都是零写入，并把焦点返回原触发按钮；批量取消保留当前选择。
- 单图查看支持 `Delete` 快捷键；输入框、下拉框和可编辑内容不会被快捷键劫持，标签的 `Delete` / `Backspace` 语义继续优先。
- Host 失败原位显示且可重试，不关闭确认框、不伪装成功。
- 桌面使用紧凑危险操作卡片；移动端使用单列大触控目标，危险按钮与取消按钮清晰分离。

## TDD 证据

先观察到以下失败，再用最小实现转绿：

1. 批量测试期望 `releaseSourceSpace`，实际收到 `recoverableRecycle`。
2. 单图测试找不到“删除当前照片”。
3. 取消确认后焦点未返回。
4. 批量流程没有应用内 `alertdialog`，仍依赖 `window.confirm`。
5. 批量取消后焦点未返回。

新增或更新的回归覆盖：

- `WebCompanionApp/tests/e2e/gallery.spec.ts`：单图精确 POST、确认文案、取消与 Esc 零写入、Delete 快捷键、焦点恢复、409 原位重试、桌面与移动端 axe。
- `WebCompanionApp/tests/e2e/slimming.spec.ts`：冻结多选、取消保留选择、焦点恢复、应用内确认、精确 `gallerySelection + releaseSourceSpace`。
- `WebCompanionApp/tests/e2e/syntheticHost.ts`：普通图库选择若不是 `releaseSourceSpace`，以 422 拒绝，避免合成环境再次掩盖真实 Host 契约。

## 验证结果

- 删除聚焦 E2E：8/8 通过（桌面与移动）。
- 全量 Web E2E：116 通过、4 个既有配置跳过、0 失败。
- Vitest：31/31 通过。
- `format:check`、lint、TypeScript typecheck：通过。
- Web 生产构建：通过。
- macOS `build-for-testing`（关闭代码签名）：`TEST BUILD SUCCEEDED`。
- 10k 合成图库：路由可交互 980 ms、DOM 713、资产卡 35、选择 P95 18.5 ms、查看器 P95 97.5 ms、long task 0、锚点偏移 0。
- 源构建产物与 App 内 `WebCompanionV2`：`diff -qr` 无差异。
- 两侧 `asset-manifest.json` SHA-256：`463e35fb5625799394ff670b91eb46a5668a2f9cfa3bbcc9023c9c929c63da14`。

## 证据边界

尝试运行两个与普通图库删除约束相关的聚焦 Swift 测试时，`xcodebuild test-without-building` 在没有启动 xctest runner、没有输出测试结果的状态下挂起，随后被中断。因此本轮只能声明 macOS 测试构建成功，不能声明这两个聚焦 Swift 测试在本轮通过。Host 实现未修改；Web payload 已按当前 Host 源码约束和既有测试定义校正。

本轮没有启动生产 Host，也没有验证真实 Photos 的“最近删除”、真实文件永久删除或收藏同步。上述结果证明合成 Host 下的协议、交互、错误处理、可访问性与打包一致性，不外推真实数据变更结果。

## 可视证据

- `evidence/gallery/imageall-react-deletion-confirmation-chromium-desktop.png`
- `evidence/gallery/imageall-react-deletion-confirmation-chromium-mobile.png`
