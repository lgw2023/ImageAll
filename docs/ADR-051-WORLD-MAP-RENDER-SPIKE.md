# ADR-051：照片世界地图 S0 渲染、S1 GPS、S2 地点标签、S3 照片下钻与 S4 图库联动

- 状态：Accepted
- 日期：2026-08-04
- 范围：macOS App 左侧「照片世界」入口、本地地图渲染运行时、GPS 位置目录、地点标签解析、视口聚合、照片下钻与现有图库精确联动
- 安全边界：自动化验证仅使用代码生成的图片、数据库和 PhotoKit 假实现；不读取或修改真实照片

## 1. 背景

产品目标是在可拖拽、缩放、旋转和俯仰的世界地图上，把地点照片数量渲染成高低不同的 3D“照片城市”。
最终数据会同时来自照片 GPS 和已确认的地点标签，但在改造目录库前，必须先证明目标 macOS / WebKit 环境能
稳定运行 WebGL2、MapLibre GL JS、deck.gl 3D 柱体和 Swift / JavaScript 双向桥接。

## 2. 决策

### 2.1 先交付独立 S0 纵切片

本切片新增左侧「照片世界」入口和独立全窗口工作区，向本地 `WKWebView` 发送 1,000 个由固定种子生成的
模拟地点聚合。页面使用 MapLibre GL JS 管理地图相机，deck.gl `ColumnLayer` / `ScatterplotLayer` 渲染照片
建筑和光晕；高度采用照片数的对数非线性函数，避免极大计数压扁其余地点。

S0 明确不新增 migration、不读取现有目录库、不从文件或 PhotoKit 提取 GPS，也不解析地点标签。界面必须
持续标注为 render spike / 模拟数据，不能把模拟照片数描述为真实图库事实。

### 2.2 运行时与网络边界

- MapLibre GL JS 5.12.0 与 deck.gl 9.3.7 的固定版本运行时、样式和完整许可证随 App 本地打包；生产页面不从
  CDN 加载代码。
- S0 固定使用 MapLibre 5.12 的 CSP UMD browser bundle 和独立本地 worker。实测 6.1 的 ESM 分片虽能在 Chromium HTTP 页面运行，
  但 `WKWebView.loadFileURL` 不执行其本地 module import，bridge 永远无法 ready；S0 不引入本地 HTTP server
  或自定义 URL scheme 来绕过这一点。`WKWebView` 也不允许 worker 直接执行或同步读取兄弟 `file://` 文件，
  因此把 CSP worker 原始字节生成为本地 base64 脚本，页面加载后只在内存中解码为 `blob:` URL，再通过
  `setWorkerUrl` 启动。此路径不产生远程代码请求，且 CSP 仍只允许 local/blob worker。
- deck 层在 MapLibre 相机创建后立即安装，不再等待可能受 source/worker 状态影响的 `style.load`；
  `style.load` 只作为可重复安装的补充事件。原生 `WKWebView` smoke 必须实际收到 `ready` 才通过。
- S0 使用 Mercator 相机和 deck.gl 独立 overlay canvas。实测 MapLibre GL JS 6 的 custom-layer framebuffer
  与 deck.gl 9.3 interleaved 模式会在渲染阶段缺失 viewport height 并崩溃；独立 canvas 仍与同一相机同步，
  可保留拖拽、旋转、俯仰、拾取和 3D 柱体。未来只有在两端兼容性测试通过后才恢复 interleaved / globe，
  不能仅为视觉名义重新引入已复现的崩溃。
- 世界轮廓固定使用随 App 打包的 Natural Earth 1:110m Admin 0 GeoJSON（公共领域），经纬网也由本地代码生成；
  两者都通过 deck.gl `GeoJsonLayer` 渲染。S0 地图从第一帧即可离线工作，不依赖 demo tile 或任何瓦片服务。
- Web 页面 CSP 只允许本地脚本、样式、数据和 blob worker；`connect-src` 不开放任何远程域名。

### 2.3 桥接协议与容量

Swift 只发送聚合对象，不发送照片路径、PhotoKit identifier 或逐项图库记录。S0/S1 payload 为：

```json
{
  "revision": 1,
  "clusters": [
    {
      "id": "demo-0042",
      "longitude": 116.4074,
      "latitude": 39.9042,
      "photoCount": 1842,
      "gpsCount": 1314,
      "tagCount": 528,
      "displayName": "北京"
    }
  ]
}
```

页面最多接受 2,000 个聚合对象。页面只在完成相机移动后回传 `cameraChanged`，并回传 `ready`、
`clusterClicked` 和安全的 `renderError`；Swift 对类型和必填字段进行解码校验。S1 的 GRDB 查询继续维持
该聚合边界，不把全量照片坐标塞入 WebView。

### 2.4 S1 位置目录与来源边界

S1 追加 migration `v031_add_asset_location`，不修改已批准的 v001-v030。每个已检查资产最多保存一条
`asset_location`：

- 文件夹图片从同一次 ImageIO 元数据读取中提取 EXIF GPS，来源记为 `embeddedGPS`；
- Apple Photos 通过正常授权后的 `PHAsset.location` 读取坐标，来源记为 `photosGPS`；
- 已检查但没有坐标的资产仍写入 `source_kind = 'none'`，避免每次扫描重复解码同一文件；
- `placeTag` 是为 S2 预留的合法来源值，S1 没有地点标签解析器，也不会写入该来源；
- `altitude_m` 为后续视觉表达预留，S1 不提取或使用高度。

坐标、来源与资产元数据在同一个 GRDB 写事务中完成 upsert。表约束拒绝半坐标、越界坐标以及
`none` 携带坐标；资产删除时位置行通过外键级联删除。migration 只建立目录结构，不遍历文件、不调用
PhotoKit，也不自动启动旧图库回填。

已有文件夹资产若尚无 `asset_location` 观察行，会在用户下一次对相应来源执行 reconcile 时重新读取一次
元数据并记录 GPS 或 `none`；已有 Photos 资产会在下一次 Photos 同步/修复扫描、且 PhotoKit 正常授权后写入
位置。在上述动作发生前，世界地图可以正确显示为空或显示“待重新扫描”的未定位状态，不能把 migration
完成误述为旧图库已回填完成。

### 2.5 S1 聚合与实时界面

「照片世界」生产界面不再使用 S0 模拟数据。SwiftUI 首次加载全局聚合，并在地图相机停止移动后按视口
重新查询；较旧的异步请求结果会被丢弃。查询只纳入当前、可用、未进入回收流程的图片，并同时返回：

- 符合条件的图片总数；
- 有坐标与无坐标图片数；
- 每个网格的照片数、GPS 数和地点标签数。

全局查询使用粗网格，视口查询根据经纬跨度自适应网格尺寸，并支持跨越 180° 经线的视口。每次最多返回
2,000 个聚合，柱体高度继续由前端按照片数进行非线性映射。S1 尚不做反向地理编码，所以详情名称使用
聚合中心坐标；城市/景区名称解析与歧义确认仍属于 S2。

### 2.6 地图视觉语言服从 ImageAll 马卡龙体系

照片世界是 ImageAll 的一个工作区，不采用独立的暗黑赛博主题。地图固定使用低饱和、浅明度的马卡龙
视觉语言：暖雾白作为水域与纸张底色，鼠尾草绿作为陆地，雾蓝、薰衣草、蜜桃和奶油黄表达由低到高的
照片密度。3D 高度仍是主要数量编码，颜色只作辅助分级，避免高密度地点变成高饱和警示色。

SwiftUI 浮层和 WebGL 页面共享同一组颜色语义、柔和描边与低对比阴影；不强制暗色模式，不使用霓虹描边、
星空粒子、扫描线或强辉光。轻微纸张纹理和缓慢色彩呼吸可保留地图的层次与辨识度，并遵守系统的
“减少动态效果”设置。后续切片若调整地图视觉，必须继续服从项目级低饱和马卡龙风格。

### 2.7 S3 提前形成“照片塔到照片”闭环

按项目的端到端加速原则，原计划在 S2 地点标签解析之后实施的 S3 照片下钻提前交付。S3 复用 S1 聚合时的
同一网格键；用户点选照片塔后，Swift 只向 GRDB 请求该网格内最近的 36 张照片目录投影，并在地图详情卡内
显示横向缩略图。点缩略图可打开 App 内预览；不会向 WebView 发送资产 ID、文件名、路径或照片字节。

下钻查询与聚合使用完全相同的图片资格条件：只包含当前、可用、未进入回收流程的图片。详情同时返回该
网格的完整照片数；超过 36 张时界面明确标注“最近 36 张 / 共 N 张”，单次查询硬上限为 120，避免高密度
地点触发无界缩略图加载。异步结果通过请求 ID 和当前照片塔 ID 双重校验，快速切换地点时不会显示旧结果。

这个顺序调整不改变 S2 的正确性门槛：地点标签仍须经过候选解析、缓存和用户歧义确认后才能写入
`placeTag`，未确认标签不能为了让照片更早出现在地图上而静默推断位置。

### 2.8 S2 地点标签采用显式请求与可追溯确认

S2 追加 migration `v032_add_place_tag_resolution`，建立 `place`、`tag_place_binding` 与
`tag_place_candidate`。`tag_place_binding` 按标签保存解析状态和 resolver 版本，候选按原始排序缓存；打开
“补全地点”面板只读取本地表，不发起地点搜索。只有用户点击某个标签的“识别地点”按钮时，才把该标签
文字交给 `MKLocalSearch`。照片、路径、PhotoKit identifier 和资产 ID 不进入 MapKit 请求。

只纳入至少关联一张人工 `accepted` 照片的 active 标签，并把“地点与场景”分组排在前面。单个候选可直接
确认为地点；多个候选进入人工选择，例如“朝阳”不会默认采用搜索结果第一项。候选上限为 8，解析结果与
resolver 版本一起缓存；相同版本的 resolved/ambiguous 结果不会重复联网，failed 允许用户显式重试。

`asset_location` 在 v032 中增加 `place_id` 外键并收紧约束：`placeTag` 必须引用已保存的 place，GPS/none
不得携带 place。canonical location 的优先级固定为：`embeddedGPS` / `photosGPS` 高于 `placeTag`。确认地点
只修改 `none` 或既有 `placeTag` 行；同一照片若命中两个不同的 resolved place，则保持 `none`，不会静默
选择其中之一。多个标签绑定到同一个 place 时只产生一个 canonical location。

接受、拒绝、清除、撤销、重命名和归档标签时，相关照片的 canonical location 在同一个标签写事务中增量
重算。重命名或归档会删除旧解析绑定，避免地点缓存继续代表已经变化的标签文字。地图聚合只在一个网格内
存在唯一 place 名称时使用该名称，否则继续显示坐标，避免把混合地点网格误命名为其中一个城市。

### 2.9 S4 从照片塔进入现有图库，并可原路返回

照片塔详情卡新增“在图库中查看全部”动作。该动作不把预览资产列表当作筛选条件，而是把聚合产生的
`WorldMapCatalogSelectionQuery` 原样放入 `AssetPageFilter.worldMapSelection`：主图库 SQL 复用相同的网格桶、
视口经纬度裁剪、跨 180° 经线规则与地图图片资格条件。因此即使同一网格桶内存在视口外照片，或资产已
不可用、变成视频、进入回收流程，也不会混入照片塔结果；图库继续使用既有 cursor 分页，不受 S3 的
36/120 张预览上限影响。

进入照片塔图库时会清除此前的来源、标签、搜索、可用状态、格式和视频筛选，并固定从照片模式开始，避免
旧筛选与地点范围静默叠加。图库顶部使用低饱和暖雾白、雾蓝和鼠尾草横幅说明当前地点范围，提供“返回地图”
与“查看全部照片”两个明确出口。地点范围仍只存在于 App 内原生查询；JavaScript 继续只收到聚合对象，不接收
资产 ID、文件名、路径或照片字节。

地图返回状态保存中心经纬度、视口边界、zoom、bearing、pitch 和选中照片塔 ID。重新创建 `WKWebView` 时，
相机在页面构造前通过本地 user script 注入；聚合返回后再调用只改变高亮、不回传 `clusterClicked` 的
`restoreSelection`。这样返回不会跳到默认世界视角，也不会把状态恢复误判为一次新的用户点击。S4 不新增
migration、不扫描旧照片，也不改变旧图库位置回填的显式触发边界。

### 2.10 S5 旧图库位置回填必须由用户按来源显式启动

照片世界顶部新增“更新照片位置”入口。打开控制面只读取本地 `source`、`asset`、`asset_location` 与
`job`，按来源显示可参与地图的图片总数、已经形成位置观察的图片数、真正有坐标的图片数，以及当前
reconcile 的持久进度；读取状态本身不入队、不清空 Photos cursor，也不访问照片来源。

只有用户点击某个来源的“开始检查”后才启动工作：文件夹来源复用既有全来源 reconcile，Apple Photos
使用 full repair 而不是安静的增量 sync，确保旧资产即使没有新的 PhotoKit change token 也会重新枚举。
两条路径继续在既有原子 upsert 中写入 GPS 或明确的 `none`，不新增 migration，也不写回、移动或重命名
原照片。控制面统计与地图使用同一图片资格边界：current、available、image，并排除处于回收生命周期的资产。

pending/running job 不重复入队；`retryableFailed` 恢复同一个 job，避免叠加第二次全库 I/O；cancel 通过持久化
job control 在安全批次边界生效，已提交的位置观察保留。cancelled/terminalFailed 是终态，再次点击“重试”
创建新 job。用户主动取消不作为全局目录扫描故障提示。控制面以暖雾白、雾蓝、鼠尾草、薰衣草和蜜桃色
呈现来源卡、进度和状态，继续服从 ImageAll 的低饱和马卡龙视觉体系。

## 3. 验收标准

1. App 左侧可进入「照片世界」，且不短暂显示上一页照片网格或右侧检查器。
2. S0 的 1,000 个确定性模拟聚合仍由单元测试保留；生产地图只接收 S1 的目录聚合。
3. 地图支持拖拽、缩放、旋转、俯仰、hover 和 click；点击柱体后 SwiftUI 显示同一聚合详情。
4. 本地 bundle 含固定版本 MapLibre / deck.gl 运行时和完整许可证，不依赖 CDN 执行代码；原生 WKWebView
   能从 App bundle 完成加载并回传 `ready`。
5. 世界轮廓、经纬网和 3D 数据层均可在断网状态从本地 bundle 启动，不发出远程请求。
6. v031 约束拒绝无效位置；合成 EXIF GPS、文件夹 reconcile、PhotoKit 假数据写入和 GRDB 聚合均有主路径测试。
7. 聚焦测试和构建不启动生产 App、不访问 `/Volumes/HDD2` 或真实 Apple Photos。
8. 地图 bundle 通过资源级视觉契约测试：浅色纸张底图、四档低饱和马卡龙照片塔，并拒绝暗色模式、
   扫描线、霓虹旧色和柱体线框。
9. 点击照片塔后只返回同一聚合网格中的合格照片；缩略图上限与截断文案明确，照片目录信息不进入
   JavaScript bridge。
10. 打开地点补全面板不触发 resolver；唯一候选只补全无 GPS 照片，多候选确认前保持未定位，且重复查看
    复用缓存。
11. `placeTag` 必须引用已确认地点；GPS 不被覆盖，两个不同地点标签不会静默二选一，标签变更会原子重算
    派生位置。
12. 从照片塔进入主图库时，全部分页结果严格复用该塔的网格桶、视口裁剪、跨经线和图片资格条件；不会受
    S3 缩略图上限限制，也不会把资产目录信息发送到 JavaScript。
13. 从照片塔图库返回后恢复地图中心、缩放、旋转、俯仰和选中照片塔；状态恢复不得额外触发
    `clusterClicked`。图库地点横幅和动作继续使用低饱和马卡龙视觉语言。
14. 打开“更新照片位置”只读取本地覆盖率和任务状态，不能创建 reconcile job、清空 Photos cursor 或读取
    照片来源；必须由用户按来源点击后才开始。
15. 回填控制面持续显示已检查/总数、已定位数与 reconcile 真实进度；运行中可取消，失败可重试；
    retryable job 原地恢复，cancelled/terminalFailed 重试创建新 job。
16. 文件夹回填复用只读元数据扫描，Photos 回填使用正常授权的 PhotoKit full repair；两者都不修改原照片，
    统计只包含与地图相同的合格图片。

## 4. 当前状态与后续闸门

S0、S1、S2、提前交付的 S3、S4 与 S5 已进入实现。自动化验证已覆盖本地 WebKit `ready`、相机与照片塔恢复、
合成 GPS 元数据、两条 reconcile 写入链路、schema/migration、地图聚合、地点标签候选/缓存/确认/GPS
优先级、聚合照片下钻、照片塔到主图库的精确空间筛选，以及位置回填的只读状态、显式启动、同 job 重试
和可恢复取消；自动化不关闭或重启用户正在运行的 App，
若当前进程早于本次构建，则由用户在方便时手动重启后加载新二进制。受保护真实图库仍需在项目所有者
明确安排下进行只读人工验证。

后续闸门是由项目所有者另行明确安排受保护真实图库的只读人工验收；在授权前只继续使用合成来源验证，
不能遍历 `.photoslibrary`、触发真实来源回填，也不能把 migration 或控制面完成描述为旧图库已经重新扫描。
