# ADR-055：全 App 资产红心与 Apple Photos 双向同步

> 状态：已决定并实施（2026-08-08，项目所有者对话批准）
> 范围：macOS 主 App；Remote/Web/iOS Companion 不在首轮范围
> 相关：`ADR-044-LIBRARY-SLIMMING-AND-RECYCLE.md`、`LIBRARY-SLIMMING-SPEC.md`、`ARCHITECTURE.md`

## 背景

照片或视频可能同时出现在普通图库、审核队列、图库瘦身、地图、预览、Inspector 与回收站。
红心表达用户对资产本身的长期偏好，不能被某个界面的瞬时状态、普通标签、内容 revision 或
派生分析生命周期取代。Apple Photos 也有独立的收藏事实，因此 ImageAll 必须在不读取原图、
不触发 iCloud 下载的前提下对账和写回公开 PhotoKit 收藏属性。

## 决策

### 1. 红心是独立用户事实

- 使用 `asset_favorite_state` 按稳定 `asset_id` 保存，不创建或复用普通 Tag。
- 状态同时保存 ImageAll 当前目标 `desired_value`、Photos 最近观测
  `photos_observed_value`、`localOnly / synced / pending / failed`、单调递增
  `intent_revision`、请求/观测/写回时间和安全错误码。
- `v035_add_asset_favorite_state` 在现有 `v034` 之后创建表和红心/待同步局部索引；既有
  migration 不改写。
- 内容 revision 变化不清除红心。永久清理媒体内容时红心事实作为 tombstone 保留；删除整个来源时
  随 Asset 级联清理。恢复产生替代 Asset ID 时在同一事务迁移状态；外部文件被识别为全新资产时
  不推断继承关系。
- 红心不进入标签计数、标签导出、模型样本、训练或建议生成。可移植导出以独立
  `favorites.jsonl` 保存状态和未完成意图。

### 2. 统一读写与 UI 投影

- 所有媒体表面从同一批量查询接口读取 `MediaFavoriteState`；普通图库、单图/视频预览、Inspector、
  待审核、图库瘦身结果/预览/回收站、地图下钻和图库总览不得维护各自事实副本。
- 已收藏始终显示红色实心心形；未收藏只在悬停、聚焦或选中时显示空心心形。待同步和失败使用附加
  图标与辅助功能文本，不只依赖颜色。
- 红心按钮消费自己的点击，不改变卡片选择、不打开预览，也不影响框选或视频悬停播放。
- 侧栏“红心收藏”复用当前照片/视频域、分页、排序、选择和预览。取消红心后只从已加载结果原位移除，
  保持已加载页数、剩余顺序和滚动位置；当前项消失时优先选择原位置后的项目。
- 普通图库与图库瘦身提供批量“加入红心/取消红心”，结果分别汇报本地成功、Photos 待同步和失败。

### 3. Apple Photos 双向同步

- 全量和增量对账读取 `PHAsset.isFavorite`。没有本地未完成意图时，Photos 观测更新 ImageAll 目标；
  存在 `pending` 或 `failed` 意图时，本地目标优先，外部值只更新观测；观测已等于目标时收敛为
  `synced`。
- 用户操作 Photos 资产时，先原子写入目标、递增 revision 并标记 `pending`。该行本身是可恢复的
  持久同步意图队列；启动恢复和显式“重试同步”按来源、小批量领取，不依赖内存任务存活。
- Adapter 必须精确解析整批 PhotoKit 标识，任一标识缺失则不提交部分写入；只使用公开
  `PHAssetChangeRequest.isFavorite`，提交后批量回读验证。只有数据库中的 `intent_revision` 仍与
  请求一致时才可标记成功，旧任务不得覆盖后续点击。
- 权限不足、图库离线或系统失败保留本地目标与安全错误码，不在后台弹系统权限框。界面显示待同步/
  失败数量，并提供重试与照片权限入口。
- 写回同时记录回读 `modificationDate`。后续持久变化与该值匹配且收藏值收敛时，证明为本次红心元数据
  变化，不推进内容 revision；离线期间无法证明原因的复合变化保守推进一次 content revision。
- 红心对账和写回只读取 PhotoKit 元数据，不请求图像数据、不直接遍历 Photos Library、不触发 iCloud
  下载。

### 4. 删除与回收保护

- 统一保护谓词是 `desired_value == true || photos_observed_value == true`。因此 ImageAll 已发出取消
  收藏但 Photos 尚未确认时仍受保护。
- 一键清理完全相同媒体时，保留全部受保护资产，只计划清理普通副本；没有红心时沿用确定性保留一项；
  全部红心时整组跳过。计划、证明和结果核验支持多个保留 ID，并区分红心保留、普通保留、计划清理与
  受保护跳过。
- 手动快速删除、可恢复回收和永久删除只要含受保护资产，就忽略“少量项目不再确认”偏好，显示专门
  红心数量警告；用户再次确认后仍允许执行。
- 文件夹回收项红心期间被到期清理跳过；取消最后一层保护时从该次操作重新获得完整 30 天期限。
  手动永久删除仍可在红心警告后执行。
- Apple Photos 回收记录可以修改 ImageAll 本地目标并显示待同步，但系统“最近删除”不受 ImageAll
  红心保护。Photos 恢复后沿用既有意图；系统永久删除时保留审计状态，不宣称同步成功。

## 冲突和失败语义

- 本地 `pending / failed` 意图优先于外部 Photos 变化；没有本地意图时 Photos 是该来源的权威观测。
- `localOnly` 只用于文件夹资产；Photos 写回成功后必须经过回读才成为 `synced`。
- 部分解析、权限、系统 mutation 或回读验证失败均不得伪造成功。错误信息不得持久化用户路径、文件名
  或 PhotoKit 标识。

## 后果与边界

- ADR-016 的“Photos 源端零写入”被本 ADR 在 `isFavorite` 这一公开元数据字段上窄化；关键词、相册、
  原图字节及其它 Photos 元数据仍不写回。ADR-044 用户确认后的系统软删除例外保持不变。
- 首轮不新增键盘快捷键，不扩展当前只显示照片的地图为视频地图，不修改 Remote/Web/iOS 协议。
- 自动化只使用临时 SQLite、合成媒体和假 PhotoKit Adapter；受保护真实照片不进入自动化验证。

## 反例

- 不得用名称为“红心”或“收藏”的 Tag 代替该事实。
- 不得因 content revision、重新分析、切换界面或清理派生缓存丢失红心。
- 不得让旧 revision 的同步完成覆盖用户较新的点击。
- 不得把 Photos “最近删除”描述成可由 ImageAll 红心暂停。
- 不得让任何自动清理任务删除仍满足统一保护谓词的资产。
