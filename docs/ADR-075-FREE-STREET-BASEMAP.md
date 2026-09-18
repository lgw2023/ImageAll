# ADR-075：使用无需密钥的免费街道底图

2026-09-09，用户明确拒绝需要付费/密钥的 MapTiler 接入，要求替换成免费方案。本决策取代 ADR-074 的服务商、认证和接口选择。

采用 MapLibre + OpenFreeMap 官方公共 Liberty 样式 `https://tiles.openfreemap.org/styles/liberty`，不需要注册或 API Key。保留离线轮廓兜底；启动直接加载在线地图，服务不可用时提示并可重试。移除 MapTiler API Key 输入、保存/清除入口、域名许可和品牌资源。新的偏好键仅记录 online/offline 模式与六类布尔开关。

根据实际官方样式的 OpenMapTiles source-layer 映射六组：boundary；transportation/transportation_name/aeroway；poi/aerodrome_label；place/water_name；landcover/landuse/park；building/housenumber。保持官方层级、缩放阈值和建筑表现，地名/兴趣点优先中文再当地名称。保留水域轮廓作为地理参照。没有“全球数十亿建筑”的覆盖承诺，具体以 OpenStreetMap 数据为准。

仅放行 tiles.openfreemap.org 的地图资源请求，不加载远程脚本，不发送照片、路径或资产 ID。服务方可见请求区域与网络地址。保留 OpenFreeMap、OpenStreetMap 以及地图源自带署名。六类开关与顶部原生信息栏共享实测避让高度，底部保留照片塔导航空间。

按用户要求直接构建 main 当前工作区并在主 App 验证；不以合成地图作为真实底图验收。

官方依据：https://openfreemap.org/ ，https://openfreemap.org/quick_start/ ，官方 Liberty style JSON。

## 主 App 实际验收

主工程 Debug 构建通过；安装到原日常 Debug App 路径，完整签名与构建包文件哈希一致，旧 App 保留于 `ImageAll.before-free-map.app`。实际窗口显示“免费街道地图已连接”，六个开关均已开启，无 API Key 输入入口。真实联网地图已显示国家/城市中文地名、行政边界、地形土地底色和区域道路。手动切换地名开关后界面状态先“已隐藏”再“已开启”。

放大至约 zoom 13.9 后建筑组达到可见倍率，但本次视口落在空旷区域，因此没有宣称实际观察到建筑或 POI 的完整覆盖。最后缩回 zoom 2.4 总览，恢复六类全开。提供方真实样式包含 building 与 building-3d 层，以及四个 poi 层；具体地区的可见效果仍以实际瓦片内容为准。本轮不运行合成测试，不将测试样式冒充真实地图。
