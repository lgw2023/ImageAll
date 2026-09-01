# Review 网格呈现上下文纵切片

日期：2026-09-01
状态：本纵切片已实现并完成合成验收；整个 Review 仍为 `in-progress`

## 产品与契约判断

功能语义以 Mac `LibraryWorkspace` 与 ADR-047 为权威，视觉继续使用独立 Nocturne 数字暗房语言。
密度对齐 Mac 的 9 档 51→620px 缩略图标尺，但在响应式 Web 网格中使用 `auto-fill`；微缩、
精细、紧凑三档变为无文字接触表，避免把 Mac 卡片 chrome 原样搬到 Web。

原比例不是“现场读原图”。按 ADR-047，Web 只向现有缩略图端点追加 `aspect=original`；Host 只读
手动预热的 `gridOriginal` 缓存，未命中则返回正方形 `gridRegular`。切换比例不生成缓存、不请求
PhotoKit，也不下载 iCloud 内容。

## 完成的闭环

- 审查队列新增微缩、精细、紧凑、标准、大图、较大、很大、特大、巨大 9 档密度，缺省标准。
- 正方形模式固定 1:1 居中裁切；原比例模式以 Host 返回图像的自然尺寸排版，因此缓存未命中的
  正方形回退仍然保持 1:1。
- `density` 和 `aspect` 写入 URL，刷新、History、概览返回和再进入队列都能重建同一呈现状态。
- 切换显示只更新已有网格和图像 URL，不改 review query key；当前卡片、选择集和 Host 队列保持。
- 控件使用真实 `select` 与 toggle button，提供动态 `aria-label`、`aria-pressed`、键盘操作和焦点样式。

## TDD 与验证证据

先新增用户行为级 RED：旧 React 队列找不到“缩略图大小”控件。实现后同一用例验证默认
标准→精细列数实际增加、当前卡片保留、URL 更新/刷新恢复、缩略图真实请求带
`aspect=original`，且切换前 Host review queue 只请求 1 次。

- `npm run typecheck` 与 `npm run lint`：通过。
- `npm run build`：通过，静态清单已生成。
- `curation.spec.ts`：14 个桌面/移动配置用例全部通过；新用例在两个尺寸均通过 axe WCAG A/AA。
- Host 既有 `testOriginalAspectThumbnailUsesCacheAndFallsBackToSquareOnMiss` 覆盖缓存命中与正方形回退；
  ADR-047 覆盖不隐式读原图/生成缓存的边界。
- 视觉证据：
  - `evidence/curation/imageall-react-review-view-controls-chromium-desktop.png`
  - `evidence/curation/imageall-react-review-view-controls-chromium-mobile.png`

## 边界与下一步

自动化只使用虚构 UUID、合成审查队列和 SVG，没有读取或遍历 `/Volumes/HDD2`、真实 Photos Library
或 iCloud。截图证明布局与控件状态，不证明真实 `gridOriginal` 命中、解码或色彩正确性。

队列的 iCloud-only 审核预览已由后续
[Review 云预览纵切片](PROGRESS-2026-09-01-REVIEW-CLOUD-PREVIEW.md)补齐。Review 总目标仍未完成：
概览仍缺每标签上限、本地模型状态、任务控制与分组折叠，因此审查概览保持 `in-progress`。
