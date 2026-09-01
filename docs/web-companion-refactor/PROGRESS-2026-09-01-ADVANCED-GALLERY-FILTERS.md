# 高级图库筛选重设计进展（2026-09-01）

## 本轮结论

新版 React 图库已经恢复 Mac 和旧 Web 具备、但重构中退化掉的高级筛选能力。Mac 只作为功能和状态语义基准；Web 没有照搬原生控件，而是采用响应式条件卡片、状态标签和大触控目标，形成独立的浏览器视觉层次。

真实 Mac Host 原本就能解析完整条件，因此本轮没有扩展协议。浏览器现在把筛选精确编码到 Host 请求和可分享 URL，也能把同一组条件无损移交给“分析当前筛选”。

## 用户可见行为

- 标签可以同时加入“包含”和“排除”条件，并选择 ALL 或 ANY 关系。
- 可以直接限定全部、已标记或未标记照片。
- 可以组合本机可用、文件缺失、不可读和不支持等可用性状态。
- 可以组合 JPEG、PNG、HEIC/HEIF、TIFF、WebP、JPEG 2000、GIF、SVG、PDF/AI、RAW、MP4/MOV 格式组。
- 切换媒体大类会移除不再兼容的格式，避免留下不可见的矛盾条件。
- 每个条件都可单独移除；“清除 N 个筛选条件”可一次复位高级条件。
- 高级状态完整写入 URL，刷新或分享后仍能复现；旧的单标签 `tag` URL 继续兼容。
- 桌面端用横向条件工作台，移动端重排为单列卡片和大触控标签；两种尺寸都保留搜索、选择和主操作空间。

## TDD 与布局回归

本轮先逐项建立失败证据，再补最小实现：

1. 混合包含/排除标签测试最初找不到“添加标签”。
2. 可用性与格式组合测试最初找不到“文件缺失”。
3. 一键复位测试最初找不到“清除 4 个筛选条件”。
4. 首版视觉检查发现筛选卡片与主控件互相覆盖；随后新增几何回归，移动端明确报告 14 处重叠。

重叠根因是旧主题样式在基础样式之后把工具栏强制改回 grid。Nocturne 主题现在显式保留新版 flex 结构，几何回归会在桌面或移动端任意可见控件相交时失败。

## 验证结果

- 高级筛选聚焦 E2E：桌面和移动端通过，包含精确 Host query、URL 重载、一键清除、无重叠和 axe。
- 图库与精简 E2E：60/60 通过。
- 全量 Web E2E：124 通过、4 个配置跳过、0 失败。
- Vitest：31/31 通过。
- `format:check`、lint、TypeScript typecheck、`git diff --check`：通过。
- Web 生产构建：通过。
- macOS `build-for-testing`（关闭代码签名）：`TEST BUILD SUCCEEDED`。
- 10k 合成图库：路由可交互 1142 ms、DOM 703、资产卡 30、选择 P95 17.6 ms、查看器 P95 138 ms、long task 0、锚点偏移 0。
- App 内 `asset-manifest.json` SHA-256：`06b27663d783e041c4dbe7fe93dbe429e390824c02c24c0cf60c67ede66cef9d`。

## 证据边界

自动化只使用合成 Host 与隔离浏览器资产，没有读取、遍历或写入 `/Volumes/HDD2/Photos Library.photoslibrary` 及 HDD2 年份目录。本轮证明筛选语义、Host 请求、URL 状态、分析移交、响应式布局和生产打包；不证明真实照片库中的格式分布、查询耗时或人工审美验收。

## 可视证据

- `evidence/gallery/imageall-react-advanced-filters-chromium-desktop.png`
- `evidence/gallery/imageall-react-advanced-filters-chromium-mobile.png`
