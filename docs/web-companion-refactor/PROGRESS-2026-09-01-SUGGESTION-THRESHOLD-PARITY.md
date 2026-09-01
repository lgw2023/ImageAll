# Web Companion 建议阈值完整对齐（2026-09-01）

## 源码审计结论

功能矩阵此前把“通用设置”标为 `parity-proven`，但当前实现证据与该结论不一致：

- Mac `AppModelSettingsView` 支持三轨默认阈值、按标签覆盖、采用样本参考值、恢复继承默认，以及按当前
  有效阈值清理低分待审建议；
- `RemoteGeneralSettingsDTO` 与 `RemoteGeneralSettingsCommandService` 已支持 `setDefault`、
  `setOverride`、`clearOverride`、`prune` 四类 mutation；
- Web `SettingsRoute` 只展示只读“建议阈值摘要”，没有任何上述操作入口。

本轮不扩展服务端协议，直接补齐已存在但未被 Web 使用的 Host 权威能力。

## 已完成

1. 设置页把只读摘要替换为三轨默认阈值编辑器；每次只提交一个 mutation，不覆盖 Mac 同时发生的模型、
   预热、工具栏或待审上限变更；
2. 新增可搜索的“按标签覆盖”模态工作台，展示每条轨道的有效值、覆盖状态与参考样本结果；
3. 支持写入覆盖、采用参考值和清除覆盖；每次成功后使用 Host 返回的完整设置快照调和界面；
4. 新增低分待审清理确认：明确当前有效门槛、不会修改阈值、不会启动图库扫描、不会删除照片或已完成
   决定；
5. 清理失败保留在确认框内，重试复用同一个 `operationID`，避免超时后的重复写入；
6. 模态框支持 Escape、关闭后焦点回退、可访问状态播报、桌面三轨布局和移动单列滚动；390 px 下所有
   按钮触控高度不小于 44 px。

## TDD 证据

三个公开工作流均先得到缺失控件的 RED，再逐条实现为 GREEN：

- 单一默认阈值更新：精确 `setDefault` payload，证明不携带其他设置字段；
- 按标签连续工作流：`setOverride` → 采用参考值的 `setOverride` → `clearOverride`，并验证 Host 回读、
  搜索与焦点回退；
- 低分清理：应用内说明与确认，首个 503 原位呈现，第二次重试复用同一操作 ID 后成功。

## 验证

- `format:check`、lint、typecheck：通过；
- Vitest：11 个文件、31 项全部通过；
- Playwright：164 项中 158 项通过、6 项按项目配置跳过、0 失败；新增设置工作流在桌面和 390 px
  移动端共 8 项通过，并执行 axe WCAG 2.1 A/AA、无水平溢出和移动触控尺寸检查；
- 10k 合成图库：fixture SHA-256 `0db043e9e228ff18deaa183a280c69b6ed05257bdbc1c388608e27042f8c34cc`，
  首卡可交互 869 ms，DOM 781，卡片 36，选择 p95 17.5 ms，灯箱 p95 112.9 ms，长任务 0，
  锚点偏差 0 px；
- macOS `build-for-testing` 退出码 0；App 内 `WebCompanionV2` 与源码构建产物逐文件一致；
- `asset-manifest.json` SHA-256：`2f558daebbb4b4f49d0f7b4b6f6c7c9bcdc68b5ba9d7f2adc63157e23400b7b9`；
- 视觉证据：
  `evidence/management/imageall-react-suggestion-thresholds-chromium-{desktop,mobile}.png`。

## 证据边界

- 所有自动化均使用合成 Host、合成标签和合成媒体，未读取、遍历或写入 HDD2、Photos Library 或
  iCloud；
- 测试证明请求、Host 回读、失败恢复和响应式交互，不证明真实建议分数的统计质量或清理后的模型效果；
- 自动 axe 不能代替人工 VoiceOver 听读验收。
