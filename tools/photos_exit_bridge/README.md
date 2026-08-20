# Photos Exit Bridge

这是一个独立于 ImageAll 产品界面的单次迁移工具，用于：

1. 通过公开 PhotoKit API 把“系统照片图库”导出为普通文件；
2. 把导出文件唯一映射回 ImageAll 现有 Photos Asset；
3. 在数据库副本中保留旧 `asset_id`，从而保留标签、收藏目标、模型样本、训练样本和回收历史；
4. 在持有 ImageAll 目录锁、先发布原生回滚快照后，原子安装验证通过的迁移库。

工具不会遍历 `.photoslibrary` 包，不接受 Photos Library 包路径，也不会原地修改输入数据库。

## 当前安全边界

- `/Volumes/HDD2/Photos Library.photoslibrary` 只用于你在 Photos 设置中人工确认“系统照片图库”；
  PhotoKit 无法按这个路径选择图库。
- `count` 和 `inventory` 只读元数据，不请求媒体字节，`network_access=0`。
- `export` 默认禁止 iCloud 网络访问。只有取得本次明确 `CloudDownloadGrant` 后才使用
  `--allow-network-access`。
- 自动化测试只使用临时 SQLite 和合成字节，不访问 HDD2。
- 计划、迁移和验证的控制台输出只有聚合计数。JSON/JSONL 报告含 local identifier、Asset UUID、
  相对路径和哈希，应放在私人目录，不提交到 Git。
- 在最终人工验收前，不删除或移动原 Photos Library，也不删除 ImageAll Application Support。

## 构建

```zsh
PHOTOS_EXIT_CODESIGN_IDENTITY="<代码签名证书名称或 SHA-1>" \
  tools/photos_exit_bridge/build_photokit_exporter.sh \
  /一个仅用于工具二进制的目录
```

生成 `Photos Exit Exporter.app`。真实迁移应使用稳定代码签名，并把 App 复制到固定位置（例如用户级
`Applications`）后再申请权限；重复 ad-hoc 签名会使 TCC 记录绑定到旧 CDHash。首次读取 PhotoKit 时
macOS 会要求照片权限。

先通过 LaunchServices 注册并申请权限（只申请权限，不枚举资产）：

```zsh
tools/photos_exit_bridge/authorize_photokit_exporter.sh \
  "/工具目录/Photos Exit Exporter.app"
```

`--help` 不访问 PhotoKit，可以直接运行 App bundle 内的 CLI：

```zsh
"/工具目录/Photos Exit Exporter.app/Contents/MacOS/photos-exit-exporter" --help
```

Python 身份迁移器不需要第三方 Python 依赖；`plan`、`migrate` 和 `verify` 会通过 `xcrun swift`
读取与 ImageAll 完全相同的 Foundation 文件修改时间和 `fileResourceIdentifier`：

```zsh
python3 tools/photos_exit_bridge/photos_exit_bridge.py --help
```

## 推荐完整流程

### 0. 先确定空间和系统图库

在 Photos → 设置 → 通用中确认目标图库已经是“系统照片图库”。不要让工具自动打开、切换或修复图库。

选择一个容量足够、可长期保留的新导出根目录。导出会保留每个逻辑 Asset 的所有公开资源，Live Photo、
RAW/JPEG 和编辑资源可能显著大于“只导出一张当前照片”的空间。先用 Finder“显示简介”评估图库规模；
不要把输出目录放在 `.photoslibrary` 内。

### 1. 先让 ImageAll 授权空导出目录

创建或选择一个**空目录**，在 ImageAll 中使用现有“连接文件夹”选择它。等待空目录的首次扫描完成，
然后完全退出 ImageAll。

这样安全作用域书签由 ImageAll 自己创建，同时数据库中还没有扫描出来的新文件 Asset，不会与旧
Photos `asset_id` 冲突。后续导出和数据库处理期间保持 ImageAll 退出。

### 2. 聚合只读盘点

```zsh
run_log=$(mktemp -d /tmp/photos-exit-count.XXXXXX)
touch "$run_log/stdout" "$run_log/stderr"
open -W -n "/固定路径/Photos Exit Exporter.app" \
  --stdout "$run_log/stdout" --stderr "$run_log/stderr" \
  --args count
sed -n '1,120p' "$run_log/stdout"
sed -n '1,120p' "$run_log/stderr"
```

只输出照片、视频、其它资产、公开资源和主资源歧义的聚合数量，不写文件、不触发 iCloud 下载。

如需生成逐项元数据清单：

```zsh
open -W -n "/固定路径/Photos Exit Exporter.app" \
  --args inventory --manifest /私人工作目录/photos-inventory.jsonl
```

Inventory 不是可迁移导出清单，因为它没有资源文件、字节数和 SHA-256。

### 3. 导出

在已经授权且仍为空的导出根目录执行：

```zsh
touch /私人工作目录/export.stdout.log /私人工作目录/export.stderr.log
open -n "/固定路径/Photos Exit Exporter.app" \
  --stdout /私人工作目录/export.stdout.log \
  --stderr /私人工作目录/export.stderr.log \
  --args export --output-root /导出根目录 --allow-network-access
```

`--allow-network-access` 只在本次已经取得 `CloudDownloadGrant` 时使用；否则省略，iCloud-only 项目会记为
`incomplete`。清单固定为 `/导出根目录/photos-exit-manifest.jsonl`。每个逻辑资产只有主资源位于可见
`assets/`；Live Photo 配对视频、RAW/JPEG 备选和调整资源位于 `.photos-exit-resources/`。ImageAll
文件夹扫描会跳过该隐藏资源目录，但完整归档仍保留这些附属字节和哈希。

导出文件名缺少扩展名时，导出器会根据 PhotoKit UTI 补上首选扩展名，避免文件夹扫描把有效媒体忽略。

中断后使用相同网络策略恢复：

```zsh
open -n "/固定路径/Photos Exit Exporter.app" \
  --stdout /私人工作目录/export-resume.stdout.log \
  --stderr /私人工作目录/export-resume.stderr.log \
  --args export --output-root /导出根目录 --allow-network-access --resume
```

恢复会跳过已完成清单记录，并删除后重试工具自有的
`/导出根目录/.photos-exit-staging/<asset-digest>` 不完整暂存目录；不修改任何 Photos 资产。全部成功后
暂存根自动移除。不要在导出完成前让 ImageAll 扫描这个目录。

### 4. 创建数据库一致快照并找出目标 source ID

ImageAll 默认数据库通常在沙盒或当前配置的外置 Application Support 中；以正在使用的实际路径为准。

```zsh
python3 tools/photos_exit_bridge/photos_exit_bridge.py snapshot \
  --database /实际路径/Catalog/ImageAll.sqlite \
  --output /私人工作目录/pre-migration.sqlite

python3 tools/photos_exit_bridge/photos_exit_bridge.py list-sources \
  --database /私人工作目录/pre-migration.sqlite \
  --output /私人工作目录/sources.json
```

在 `sources.json` 中选择步骤 1 创建的 folder source ID。`plan` 和 `migrate` 拒绝带 WAL/SHM/journal 的
活动数据库，只接受独立快照。

### 5. 只读计划

```zsh
python3 tools/photos_exit_bridge/photos_exit_bridge.py plan \
  --database /私人工作目录/pre-migration.sqlite \
  --manifest /导出根目录/photos-exit-manifest.jsonl \
  --export-root /导出根目录 \
  --destination-source-id <folder-source-uuid> \
  --output /私人工作目录/migration-plan.json
```

`status = ready` 才能继续。以下任一情况会 `blocked`：

- ImageAll 中 available Photos Asset 没有导出记录；
- 资源未完成、主资源歧义、大小或 SHA-256 不一致；
- 活动回收生命周期；
- 目标 file locator 已存在；
- 当前 Photos identity 不唯一。

导出中没有旧 ImageAll identity 的新资产不会阻塞；它们以后由普通文件夹扫描创建新 Asset。旧数据库中
已经 missing/recycled 的 tombstone 不会复活，也不阻塞可用资产迁移。

计划 schema v2 还会为每个匹配项记录 ImageAll 口径的 `modified_at_ns` 和非空
`resource_id_hex`。迁移前两者必须仍与导出文件一致；不能取得稳定 Foundation 指纹时失败关闭。

### 6. 迁移数据库副本并验证

```zsh
python3 tools/photos_exit_bridge/photos_exit_bridge.py migrate \
  --database /私人工作目录/pre-migration.sqlite \
  --plan /私人工作目录/migration-plan.json \
  --output /私人工作目录/migrated.sqlite

python3 tools/photos_exit_bridge/photos_exit_bridge.py verify \
  --database /私人工作目录/migrated.sqlite \
  --plan /私人工作目录/migration-plan.json \
  --output /私人工作目录/verification.json
```

验证包括 `integrity_check`、`foreign_key_check`、locator/指纹、content revision 和用户事实计数守恒。
迁移把 Photos 收藏同步状态收敛为文件资产 `localOnly`，并使来源级相似度索引变为 `stale`；不会删除
Feature Print 或模型样本，因为两者存在级联外键关系。目标文件夹来源会激活，旧 Photos 来源会停用，
相关 Photos reconcile job 会取消；不可用 Photos tombstone 仍保留。

### 7. 原子安装并保留原生回滚快照

只有 `verification.json` 的 `status = passed` 且哈希绑定当前迁移库时才能安装。ImageAll 必须完全退出：

```zsh
python3 tools/photos_exit_bridge/photos_exit_bridge.py install \
  --database /私人工作目录/migrated.sqlite \
  --verification /私人工作目录/verification.json \
  --live-database /实际路径/Catalog/ImageAll.sqlite \
  --backups-directory /实际路径/Backups \
  --app-version <当前-App-版本> \
  --output /私人工作目录/install-report.json
```

`install` 会取得 `Runtime/catalog.lock`，收敛生产库 WAL/SHM，先把替换前数据库发布到
`Backups/<snapshot-uuid>/`，再同卷暂存并原子替换 `Catalog/ImageAll.sqlite`。安装报告同时记录前后哈希、
原生回滚快照和保留的 previous database；任一步失败会自动回滚，不依赖 UI 选择任意文件。

需要单独发布一个已经验证的数据库副本时，仍可使用 `package-snapshot`；它不安装生产库。

### 8. 验收和保留期

安装后先做一次目标文件夹真实重扫，再完成以下验收：

- 照片/视频可从普通文件夹显示；
- 标签、拒绝/接受决定、红心、训练样本和个人模型仍在；
- 旧 identity 的 content revision、Foundation 指纹和已有位置/人工地点事实不变；
- 导出但此前没有 ImageAll identity 的文件全部由普通扫描新增；
- 目标来源没有 `unreadable`、`missing` 或重复 current path；
- 回收历史没有复活为可用媒体；
- 随机抽查 Live Photo、RAW/JPEG、编辑照片和视频；
- 完成一次目标文件夹对账并等待来源相似度索引重建。

至少保留原 Photos Library、迁移前数据库快照、ImageAll Application Support 和完整导出清单，直到多轮
启动、抽查和备份恢复均通过。退出 Photos 与删除原图库是两个不同决定；本工具不执行后者。

## 自动化验证

```zsh
python3 -m unittest discover -s tools/photos_exit_bridge/tests -v
```

测试构建带照片用途说明的独立导出器，但只运行 `--help`；不会请求 Photos 权限或访问真实图库。
