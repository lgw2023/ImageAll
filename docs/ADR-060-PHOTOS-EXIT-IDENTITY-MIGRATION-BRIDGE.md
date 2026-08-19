# ADR-060：独立 Photos 退出与资产身份迁移桥

> 状态：已决定，实施中（2026-08-19，项目所有者批准“全面启动”）
> 范围：独立迁移工具；不把照片导出能力加入 ImageAll 产品界面
> 相关：`LOCAL-TEST-DATA-SAFETY.md`、`ADR-052-EXTERNAL-FOLDER-ASSET-REAPPEARANCE.md`、
> `STAGE-4-RECOVERY-IMPLEMENTATION-SPEC.md`

## 背景

项目所有者计划退出 macOS Photos，把系统图库中的照片和视频导出为普通文件，同时保留 ImageAll
已经积累的标签、收藏、模型样本、训练记录、回收历史和其它按稳定 `asset_id` 关联的用户事实。

直接把导出目录作为新文件夹来源扫描会为每个文件创建新的 Asset UUID。旧用户事实仍在数据库中，
但会继续指向 Photos locator，因而不能自动投影到新文件资产。Photos 可移植导出也不包含媒体字节，
不能单独完成退出。

受保护真实图库是 `/Volumes/HDD2/Photos Library.photoslibrary`。该绝对路径只标识需要人工确认的
图库，不是工具的文件系统输入。PhotoKit 只能访问用户在 Photos 中设为“系统照片图库”的图库，
不会也不能按这个路径选择图库。

## 决策

### 1. 独立工具与公开接口

在 `tools/photos_exit_bridge/` 提供两个独立组件：

1. PhotoKit 导出器：经系统照片授权枚举逻辑资产，导出公开 `PHAssetResource`，生成版本化 JSONL
   清单；不遍历或解析 `.photoslibrary` 包。
2. 身份迁移器：只处理 ImageAll SQLite 快照、导出清单和导出目录；提供 `snapshot`、`plan`、
   `migrate`、`verify` 子命令。它永不原地覆盖生产数据库。

控制台只输出聚合数量和错误码。逐项 PhotoKit 标识、Asset UUID、相对路径和 SHA-256 只写入用户
指定的私有报告文件。

### 2. 导出资源和主资源选择

- 每个 PHAsset 的全部公开资源均导出，包括照片、视频、Live Photo 配对视频、RAW/JPEG 备选资源、
  调整数据和可用的全尺寸资源。
- ImageAll 的单 locator 指向一个主资源。照片优先选择 `fullSizePhoto`，其次为 `photo`、
  `alternatePhoto`；视频优先选择 `fullSizeVideo`，其次为 `video`。这与当前 ImageAll PhotoKit
  Adapter 的资源优先级一致。
- Live Photo 的主照片进入 ImageAll；配对视频继续作为同一逻辑资产的附属导出资源，不自动创建第二个
  ImageAll Asset。主资源写入可见 `assets/`，附属资源写入 ImageAll 文件夹枚举器会跳过的隐藏
  `.photos-exit-resources/`。RAW/JPEG、编辑版本和无法确定主资源的项目进入人工复核报告，不猜测。
- 每个导出文件记录字节数和 SHA-256；恢复运行只接受与清单完全一致的已完成文件。

### 3. iCloud 与源端零写入

- 盘点只读取 PhotoKit 元数据，不请求媒体字节，不触发 iCloud 下载。
- 实际导出默认 `networkAccessAllowed = false`。允许下载 iCloud-only 资源必须由项目所有者另行授予
  本次 `CloudDownloadGrant`，并明确输出目录和空间预算。
- 工具没有 Photos mutation 代码，不调用删除、编辑、导入、相册或关键词写入 API。
- 所有自动化测试仅使用临时 SQLite 和合成媒体，不访问 HDD2 受保护路径。

### 4. 目标文件夹授权

安全作用域书签必须由沙盒化的 ImageAll 通过系统目录选择器创建，独立工具不能伪造或移植该授权。
因此项目所有者先创建空导出目录，使用 ImageAll 现有“连接文件夹”选择它，等待空目录首次扫描完成后
退出 ImageAll，再让独立导出器写入该目录。迁移器接收这个 folder source ID。这样既取得真实书签，
又避免扫描提前创建新文件 Asset。

如果该来源已经扫描并在目标相对路径创建新 Asset，首版迁移器拒绝冲突并报告；只有证明新 Asset
没有标签、收藏、模型样本、回收记录等用户事实后，后续版本才可以增加受控合并。首版推荐连接后立即
退出 App，再对一致快照执行迁移。

### 5. 身份迁移语义

只有同时满足以下条件的项目自动迁移：

1. 清单中 PhotoKit local identifier 唯一；
2. ImageAll 快照中存在唯一的 current Photos Asset；
3. 主资源存在，字节数和 SHA-256 与清单一致；
4. 目标 folder source 存在，且目标 current file locator 不冲突；
5. Asset 不处于 `recycled`，也没有 `pending/recycled/restoring/purging` 回收生命周期。

命中时保留旧 `asset.id`，把 locator/source 切换为目标文件，写入文件指纹，并将 Photos 收藏同步状态
收敛为文件资产的 `localOnly`。标签、拒绝/接受决定、收藏目标、模型样本、训练样本和历史回收事实
因为继续引用同一 `asset_id` 而保留。

迁移保持原 `content_revision`。实现审计发现 `tag_model_sample` 通过复合外键依赖 `feature`，删除
Feature Print 会级联删除模型样本，与本任务的数据保留目标冲突。因此首版保留 Feature Print、模型
样本、预测和派生图；导出主资源必须采用 ImageAll PhotoKit Adapter 同样的优先级，确保仍是同一逻辑
内容。来源级相似度成员可以标记为 stale 后重建，但不得以清缓存为名级联清除用户训练证据。

若 RAW/JPEG、编辑版本或主资源选择不能证明为同一逻辑内容，该资产进入人工复核，不通过递增
`content_revision` 静默切断模型样本。以后需要重新提取特征时，应新增受控“重算并重建个人模型”阶段，
不属于首版身份迁移事务。

无法唯一匹配、缺失、重复、主资源不确定、哈希不一致、回收中或 locator 冲突的项目一律只报告，
不自动更改。

### 6. 快照、验证和切换

1. `snapshot` 使用 SQLite backup API 生成一致快照并执行 `quick_check`；
2. `plan` 只读生成计划和不确定项报告，绑定数据库及清单 SHA-256；
3. `migrate` 从已绑定快照创建新的输出数据库，不覆盖输入；
4. `verify` 执行 `integrity_check`、`foreign_key_check`、计数、locator、指纹和用户事实守恒检查；
5. 只有验证通过后，才另行请求项目所有者批准对 App 自有生产数据库做可恢复切换。

原 Photos Library、原 ImageAll 数据库及其 Application Support 模型文件在人工验收完成前全部保留。
本 ADR 不授权删除、移动、修复或改写这些原始数据。

## 最小验收

- 合成端到端测试证明唯一匹配项目保留 `asset_id`，标签、收藏、模型样本和删除历史计数不变；
- 歧义、哈希不一致、活动回收和目标 locator 冲突均 fail closed；
- PhotoKit 导出器可构建，静态审计不存在 Photos mutation API，也不含 `.photoslibrary` 遍历；
- 自动化产物仅写入测试创建的临时目录；不访问受保护真实图库。
