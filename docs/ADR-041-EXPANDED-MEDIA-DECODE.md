# ADR-041：扩大静态、RAW 与矢量文档解码

> 状态：已决定（2026-07-22；2026-08-11 扩展矢量文档边界）
> 取代：ADR-012 中「GIF、RAW 明确延后」的格式边界；ADR-012 其余阶段 1 范围仍有效  
> 依据：本机 catalog 只读统计（未打开受保护原图像素）

## 背景

生产 catalog 显示「2023 vv粒」等文件夹来源中，大量富士 `.RAF`（`com.fuji.raw-image`）被标为 `unsupported` 或 `unreadable`，另有少量 Adobe RAW、JPEG 2000、静态 GIF。同时存在大量已在允许清单内的 `public.jpeg` `unreadable`（空宽高），那是扫描解码失败诊断问题，不是扩格式本身。

旧分类器对 `CGImageSource` 帧数 `!= 1` 一律 `unsupported`。RAF 常见「RAW + 内嵌预览」多图，即使将来把 UTI 加入允许清单仍会全部落成禁止号。

## 决策

1. **批准入库为 `available` 的 media UTI（文件夹与 Photos 对齐）**  
   - 既有：JPEG、PNG、HEIC、HEIF、TIFF、WebP  
   - 新增：`com.fuji.raw-image`、`com.adobe.raw-image`，以及符合 `public.camera-raw-image` 的其它 camera-raw 族 UTI（以运行时 UTI 继承判定，不靠扩展名）  
   - 新增：`public.jpeg-2000`  
   - 新增：静态 `com.compuserve.gif`（单帧、非动画）
   - 新增：`public.svg-image`
   - 新增：单页 `com.adobe.pdf`
   - 新增：单页、且文件载荷可由 Core Graphics 识别为 PDF 的 `com.adobe.illustrator.ai-image`

2. **明确不进入 `available`**  
   - 动画 GIF / 非 RAW 多帧容器（多帧 TIFF 等）仍为 `unsupported`
   - 多页 PDF、多页 PDF 兼容 AI 为 `unsupported`
   - 传统 PostScript/旧版非 PDF AI、损坏的 SVG/PDF/AI 为 `unreadable`
   - EPS、SVGZ、Live Photo 视频伴随资源不纳入本次支持集

3. **解码级联**（分类探活与派生缩略图/预览共用）  
   1. Image I/O `CGImageSource`  
   2. 矢量文档兜底：SVG 由 AppKit 解码；PDF/AI 先由 Core Graphics 验证为单页 PDF，再由 AppKit 栅格化
   3. Core Image RAW（仅 camera-raw 族）
   4. LibRaw（仅前三级失败且为 camera-raw 族）
   派生缓存仍只写 JPEG/PNG，不落盘 RAF/DNG 原样。

4. **RAW 多帧规则**  
   camera-raw 族允许 `frameCount >= 1`；主帧优先取最大像素帧，否则 index 0。非 RAW 仍要求单帧静态。

5. **不可读 JPEG**  
   保留/聚合分类失败原因（source 创建失败、0 帧、无尺寸），依赖重扫；不为本问题引入第二套 JPEG 解码器。

6. **已入库资产**  
   新策略不隐式改写历史行；用户对文件夹来源执行 reconcile/rescan 后按新规则更新 `availability` / `media_type`。

7. **矢量文档语义**
   图库只把矢量原件只读栅格化为缩略图和预览，不提供编辑、分页浏览、外部资源加载或脚本执行。SVG 的透明区域保留在 PNG 派生缓存中；PDF/AI 原件不被改写。

## 后果

- 共享单一批准 UTI / camera-raw 判定，避免 Classifier、DerivedImage、Photos 三处漂移。  
- SVG、单页 PDF 和 PDF 兼容 AI 复用既有分类、网格、预览和派生缓存主路径。
- 自动化测试只用合成或可再分发 fixture，不读 `/Volumes/HDD2` 受保护路径。  
- LibRaw 以 Vendor 静态库形式链接，仅作兜底。

## 反例

- 不得把多页 PDF/AI、传统非 PDF AI、EPS 或 SVGZ 标为 `available`。
- 不得为支持缩略图而执行 SVG 脚本、访问网络资源或改写矢量原件。
- 不得在 Image I/O 已成功时调用 LibRaw。  
- 不得因扩格式清除人工标签或静默删除 `unsupported` 历史资产。
