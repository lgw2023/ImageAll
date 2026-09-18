# ADR-074：照片世界详细街道底图与六类图层选择

日期：2026-09-09。状态：已被 ADR-075 取代；用户取消 MapTiler，现使用免费 OpenFreeMap。工作区：ImageAll-Web-Dev / lgw/imageall-web-dev。

## 问题与决定

用户确认使用 MapLibre + MapTiler，并要求行政边界、道路、兴趣点、地名、土地覆盖、建筑六类信息均可独立选择。
ADR-051 的 S0 离线轮廓只有国家几何形状，无法承载街道浏览。本决策将其调整为离线兜底；使用官方 Streets v4
样式和 Planet v4 数据，保留现有 MapLibre 5.12 / deck.gl 独立叠加画布、照片塔与下钻桥接。

- 六类默认全部开启，按实际 source-layer 分类，并保留官方层顺序、过滤和 minzoom/maxzoom。
  行政边界不包含地名；道路包含道路标注及交通网络；建筑包含建筑轮廓和门牌；土地覆盖包含植被和土地用途。
  水域底色和河流线条保留，以维持地理参照。未知图层保持官方默认，不凭显示名称猜测。
- 优先中文地名，无中文时回退当地名及原样式表达式；保留路号、门牌和图标表达式。
- 缩放上限提升到 22，让街道和建筑可见；高倍率下照片塔的半径和高度一起缩小，避免遮住街区。
- 地图内提供折叠“地图图层”面板、六个开关、底图选择和 API key 配置/清除入口。
  本地保存公开客户端 key 和图层偏好，不进入仓库、日志、桥接事件或 URL 导航参数；存储不可用则明确提示仅本次有效。
  不使用演示 key。没有 key 时展示配置引导，不假装联网底图已加载。普通 MapTiler 客户端 key 不是服务器秘密。
- 只在启用在线底图且配置 key 后请求 api.maptiler.com；按视口加载样式、瓦片、字形和精灵。
  照片字节、路径、资产 ID 不参与请求。地图服务可看到视口对应的瓦片请求及 IP；界面说明此网络边界。
- CSP 仅对地图文档放行 https://api.maptiler.com 的 connect/img；不开放远程脚本，不更改普通图库页面网络策略。
  保留 MapTiler / OpenStreetMap 署名。失败、超时、配额或 key 错误回退离线并提供重试，不向照片渲染桥接发送底图失败。
- 不承诺每个地点均有全部数据或建筑精确高度。“Billions of buildings”是供应商整体覆盖描述。
  本轮使用 Streets 的建筑表现，不额外推测性加入逼真 3D 建筑模式。

## 隔离与验收

不修改主工作区，不启动真实 Swift Host、不读取真实照片、不替换日常 App。使用共享 WorldMap 资源的独立合成页面
验证六类可见性、偏好恢复、缩放、照片选择连续性、缺 key、失败回退与网络域名限制；保留现有键盘导航回归。
真实地图服务效果需有用户提供的有效 key 后验证；合成样式通过不等于 MapTiler 实网或日常 App 验收。

## 官方依据

- https://docs.maptiler.com/schema/planet-v4/
- https://docs.maptiler.com/cloud/api/maps/
- https://docs.maptiler.com/sdk-js/examples/switch-from-maplibre/

## 验证结果

- `node scripts/test_world_map_basemap.js`：使用真实 MapLibre/deck 渲染器和自行生成的 MVT，六类独立显示/隐藏、
  中文地名绘制、zoom 16、偏好重载、照片选择保留、缺 key 零请求、403 回退重试、在途请求取消和资源域名校验通过。
- 现有 `scripts/test_world_map_keyboard_navigator.js` 回归通过。
- 独立 `com.gwlee.ImageAll.MapSmoke` 验证本地 file URL 的 WebKit 加载、六个控件、本地偏好写入、zoom 16 和合成照片选择通过；
  使用 nonPersistent 网站数据存储，禁用 fetch，不启动 ImageAll composition root 或图库。
- Mac Debug 构建通过，最终产品和中间文件均在本 worktree `.build/maptiler-*`；五个地图资源与源码 SHA-256 一致。
- 主工作区文件状态摘要前后均为 `9a55c805d0ef68b608de5aee1b827de4cec9ada7de9b8ca371f4df367e54f268`。
- 截图、结果和构建路径注意事项见 [验证记录](maptiler-20260909/README.md)。未使用真实照片或有效 MapTiler key，
  不把合成样式验证描述为真实底图覆盖、供应商实网兼容或日常 App 发布验收。

## 主 App 集成补充（2026-09-09）

用户要求直接在主 App 查看六类内容。本轮将上述共享地图资源与 Host 资源路由集成到 main 当前工作区，并直接构建、替换和在主 App 验证配置入口。此前隔离验收约束描述的是开发阶段，不再阻止本次明确要求的主 App 交付。地图图层面板跟随原生顶部信息栏的实测高度，六个开关排在连接设置之前；面板滚动高度同时预留底部照片塔导航位置。仍需有效 MapTiler API Key 才能进行真实街道数据验收。
