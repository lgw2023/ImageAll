# Web Companion 持续功能对齐：单图云端恢复与建议决策

日期：2026-09-01
状态：本轮纵切片已实现并完成合成验收；总目标继续实施中

## 本轮判断

上一轮完成了新版 Web 的独立视觉重设计，属于对目标的有效进展，但并不能证明细粒度功能已经与
Mac/旧 Web 对齐。本轮重新从 Host 路由、旧 Web 调用点、新 React API 和实际组件四处交叉盘点，
确认功能矩阵原先的“单图查看已完成”粒度过粗，漏掉两个用户可直接遇到的断点：

1. 新查看器遇到仅存在于 iCloud 的照片时只有通用失败占位，没有旧 Web 已具备的显式获取、真实
   进度、取消和重试闭环。
2. `AssetDetail.pendingSuggestions` 已被严格解码，但 React 查看器没有渲染它，用户无法在单图中
   处理 Host 已提供的待审 AI 建议。

## 已完成

### 1. 受保护单图预览加载

- 图片预览改为通过统一认证客户端读取 Blob，账户认证模式可以携带内存中的认证头；不把认证材料
  放入 URL。
- 对象 URL 在切图、关闭和重新加载时回收；视频继续使用浏览器原生同源 Range 媒体路径。
- 409 `cloud preview required` 被识别为明确的可恢复业务状态，其他失败仍保持普通错误语义。

### 2. iCloud 有界预览生命周期

- 只有用户点击“从 iCloud 获取预览”后才开始请求，普通浏览和相邻预取不触发下载。
- 支持 Host `cloudPreviewLifecycle`：客户端 operation ID、Host 权威进度、轮询、取消、失败重试、
  完成后重新读取普通受保护预览。
- 切图或关闭查看器时取消仍在进行的生命周期操作，并用资产 ID 和请求代次拒绝陈旧结果。
- 未声明新能力的旧 Host 保留原有同步 `/cloud-preview` 回退；同样必须由用户显式触发。
- 服务器错误被收束为用户可理解的恢复文案，不显示内部状态字符串或本机路径。

### 3. 单图待审 AI 建议

- 显示 Host 详情中的建议标签和四种来源：特征向量、标准模型、个人模型、超级个人模型。
- 默认展示 5 条，剩余建议渐进展开；展开后焦点进入第一条新增建议。
- “属于 / 不属于”直接复用既有批量标签决定 API，提交当前资产与精确 tag ID；成功后沿用现有
  Host 回读、撤销和状态通知链路。
- 桌面与移动端均保持可触控按钮、可滚动检查器和可访问名称。

## 自动化与截图证据

- 单元/契约：`src/api/contracts/asset.test.ts` 覆盖云端生命周期 enum、UUID 和 0...1 进度边界。
- 浏览器：`tests/e2e/gallery.spec.ts` 覆盖点击前零下载、42% 进度、取消、重试完成、旧 Host 回退，
  以及 6 条建议的展开和精确决定；桌面与 390px 移动视口均运行 axe WCAG 2.1 A/AA 检查。
- 截图：
  - `evidence/gallery/imageall-react-cloud-preview-chromium-desktop.png`
  - `evidence/gallery/imageall-react-cloud-preview-chromium-mobile.png`
  - `evidence/gallery/imageall-react-pending-suggestions-chromium-desktop.png`
  - `evidence/gallery/imageall-react-pending-suggestions-chromium-mobile.png`

所有浏览器数据均为虚构 UUID、合成 SVG 和模拟 Host 响应。没有访问 `/Volumes/HDD2`、真实
Photos Library 或真实 iCloud，也没有启动生产 Host。

## 本轮验证结果

- `npm run format:check`、`npm run lint`、`npm run typecheck`：通过。
- `npm run test:run`：11 个文件、30 个测试通过。
- `npm run build`：Vite 生产构建与静态清单生成通过。
- `npm run test:e2e`：88 项中 84 通过、4 项按项目配置跳过、0 失败；覆盖桌面与 390px 移动端。
- 10k 合成图库：`routeInteractiveMs=945`、`domNodes=630`、`assetCards=28`、
  `selectionP95Ms=17.5`、`viewerP95Ms=111.4`、`longTaskCount=0`、`anchorDelta=0`。
- Mac `build-for-testing`：`TEST BUILD SUCCEEDED`。
- Host 定向测试：
  - `testWebV2AssetStoreUsesAuditedManifestHashesAndSPARouteAllowlist` 通过；
  - `testCloudPreviewLifecyclePublishesProgressCancelsAndCompletes` 通过。
- 源静态目录与构建 App 中 `WebCompanionV2` 的递归 diff 为空；`asset-manifest.json` SHA-256 为
  `1adf027e3d2dfe5ba807ce711c1957124ab7a79a99a88d98b99be4f07030c443`。

## 后续进展

这里列出的三个缺口已在
[PROGRESS-2026-09-01-NOCTURNE-AND-GALLERY-WORKFLOWS.md](PROGRESS-2026-09-01-NOCTURNE-AND-GALLERY-WORKFLOWS.md)
完成：当前单图即时模型、收藏同步精确重试，以及新建标签并原子应用到冻结选区。总目标仍需继续按
“Mac 表面 → Host 路由 → 旧 Web → 新 React → 自动化证据”粒度审计，不能用页面级绿色状态替代
表面级功能核对。
