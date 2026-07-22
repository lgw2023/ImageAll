# ADR-041：扩大静态/RAW 解码（Image I/O 优先 + LibRaw 兜底）

> 状态：已决定（2026-07-22）  
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

2. **明确不进入 `available`**  
   - `public.svg-image`、`com.adobe.illustrator.ai-image`  
   - 视频、PDF、Live Photo 视频伴随资源  
   - 动画 GIF / 非 RAW 多帧容器（多帧 TIFF 等）仍为 `unsupported`

3. **解码级联**（分类探活与派生缩略图/预览共用）  
   1. Image I/O `CGImageSource`  
   2. Core Image RAW（仅 camera-raw 族）  
   3. LibRaw（仅前两级失败且为 camera-raw 族）  
   派生缓存仍只写 JPEG/PNG，不落盘 RAF/DNG 原样。

4. **RAW 多帧规则**  
   camera-raw 族允许 `frameCount >= 1`；主帧优先取最大像素帧，否则 index 0。非 RAW 仍要求单帧静态。

5. **不可读 JPEG**  
   保留/聚合分类失败原因（source 创建失败、0 帧、无尺寸），依赖重扫；不为本问题引入第二套 JPEG 解码器。

6. **已入库资产**  
   新策略不隐式改写历史行；用户对文件夹来源执行 reconcile/rescan 后按新规则更新 `availability` / `media_type`。

## 后果

- 共享单一批准 UTI / camera-raw 判定，避免 Classifier、DerivedImage、Photos 三处漂移。  
- 自动化测试只用合成或可再分发 fixture，不读 `/Volumes/HDD2` 受保护路径。  
- LibRaw 以 Vendor 静态库形式链接，仅作兜底。

## 反例

- 不得把 SVG/AI/视频标为 `available`。  
- 不得在 Image I/O 已成功时调用 LibRaw。  
- 不得因扩格式清除人工标签或静默删除 `unsupported` 历史资产。
