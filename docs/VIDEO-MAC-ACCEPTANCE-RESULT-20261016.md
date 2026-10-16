# Mac 视频工程验收结果（2026-10-16）

结论：P0–P7 的 Mac 必需工程验收通过。此前剩余的开发签名、外部播放器真实焦点往返、瘦身整页可恢复回收与恢复均已闭合。验收采用当前 Xcode 项目、合成媒体、临时数据库与 fake PhotoKit；真实来源的完整视频路线与发布安装不在本结论内。

## 版本与产物

- 项目：`/Volumes/SSD1/ImageAll/ImageAll.xcodeproj`，scheme `ImageAll`，Debug / My Mac / arm64。
- 起始 HEAD：`d07538bc7088c476a5c0ba2ba3fba93f4477b1cb`。当前工作区有保留的并行改动；本报告所在本地提交交付本轮修改，完整输入与差异见外部清单，不称为纯提交构建。
- 证据根：`/Volumes/SSD1/.codex-builds/video-completion-20261016`。最终源码文件摘要、工作区 diff、产物及日志摘要由该目录 `final-verification.json` 绑定。
- 正常App输出：`final-normal/Products/ImageAll.app`；测试产品：`mac/Products/ImageAll.app`。本轮没有覆盖或重启日常 Xcode 正在运行的 App，没有安装或发布。
- 两条实际 UI 路线使用同一次 `event-pump-test-build.log` 的代码和测试产品。其后仅修改回收结果的数量文案：视频“段”、照片“张”；最终 `final-wording-build.log` 和 `final-tests.log` 验证该差异。保留 UI 前后版本的明确区别，未冒称最终文案又被整条点击一遍。

## 本轮实际结果

下表路径均相对于证据根。

| 验收项 | 结果 | 权威证据 |
|---|---|---|
| 最终正常开发签名构建 | PASS | `final-normal-build.log`：BUILD SUCCEEDED；`final-normal-verification.json`：完整签名校验退出0、没有测试bundle |
| 最终默认签名测试构建 | PASS | `final-wording-build.log`：TEST BUILD SUCCEEDED；未设置 CODE_SIGN_IDENTITY / CODE_SIGN_ENTITLEMENTS 覆盖 |
| 最终必要回归 | PASS，71/71，0失败、0跳过 | `final-tests.log`、`tests-selection.json`、`final-test-product-verification.json` |
| 宿主修订后的播放器回归 | PASS，6/6 | `post-host-regression.log`；后续完整71项已覆盖同组用例 |
| 外部播放完整生命周期 | PASS，1/1，272.845秒 | `external-ui-passed/tests.log`、`player-observations.json`、`lifecycle-summary.json` |
| 系统播放器打开正确文件并播放 | PASS | `external-ui-passed/quicktime-verification.json`：证据目录内的合成MP4，播放开关on、进度实际前进 |
| 瘦身比较、回收、恢复 | PASS，1/1，216.225秒 | `slimming-ui-passed/tests.log`、`slimming-observations.json`、`operation-summary.json`、`slimming-result.json` |
| 既有分片证据复核 | PASS，14份已通过UI日志存在且终结为0失败 | `historical-ui-evidence-audit.json`；不是重新运行这些UI |

外部播放捕获到实际前台播放、后台释放、返回前台 ready 且暂停；同时记录 `NSApplication.isActive`、窗口 key 状态、系统前台进程和播放器状态。用户协助实际前台切换，agent 操作系统播放器并核对 URL 与进度。没有用合成通知代替系统焦点。

瘦身使用独立目录内的两份合成 MP4，真实临时目录数据库和回收服务。两段各有12个播放采样周期；确认面板显示已核验2项、红心保留1项、待清理1项，并明确完整原件字节依据。CUA 仍在确认弹窗崩溃，用户协助点击“可恢复回收”；agent 随后进入回收站并恢复。采样证明非收藏副本离开原位置、收藏始终存在、回收站恢复后清零；测试继续核对两份文件字节相等和实际可解码。

恢复文件 SHA-256：`57ef6cebde10a98222445da47a6df3b5c932983076def56d99dcc92c09fd78cb`，与输入合成素材一致。没有使用快速永久清理。

## 条款组与共享证据

| 范围 | 完成依据 |
|---|---|
| P0 / P7 版本、安全与交付 | 工作区快照和最终源码清单、正常/最终构建、71项清单、本地提交；未暂存并行改动 |
| P1 浏览、整理、播放与释放 | 既有图库/审核/音量/倍速/全屏UI；最终 LibraryVideoViewingTests / LibraryWorkspaceModelTests；本轮真实外部播放往返与瘦身比较 |
| P2 元数据、筛选、地图与云状态 | 最终 FolderMediaClassificationTests / AssetCatalogQueryTests / WorldMapCatalogS1Tests；历史 metadata-ui-1 / map-ui-5 / cloud-ui-1 的实际操作 |
| P3 建议、模型域、人工事实与撤销 | 最终 ContextualTagFeedTests、AppPersonalModelRebuildCoordinatorTests、批量/缺模型用例；历史 feed-ui-2 / batch-review-ui-3 / models-ui-1 |
| P4 完整原件与安全重复处理 | 最终 IdenticalDuplicateDetectionTests / LibrarySlimmingRecycleTests、计划变化拒绝；本轮真实合成比较、收藏保护、可恢复回收与恢复 |
| P5 有限多帧、冻结证据与候选 | 最终多帧 checkpoint / 修订 / 损坏重建 / 训练建议证据用例；历史 analysis-ui-bounded / frozen-review-ui-final / candidate-ui-final |
| P6 混合故事与导出 | 最终 TimeStoryFeatureTests 覆盖实际渲染、运动/方向、原声/静音/配乐、保存重开和协议恢复；历史片段/工作区/QuickTime导出证据 |

历史分片分别属于历史产品；最终71项为当前源码的相关回归。共享证据不扩展为所有设备、所有编码或真实图库性能承诺。

## 当前日常 App 的有限核查

运行实例为 `/Volumes/SSD1/Xcode/DerivedData/Build/Products/Debug/ImageAll.app`，由 Xcode debugserver 启动；其完整签名校验通过，身份及哈希见 `current-app-identity.json`。

总览显示51,672项，其中照片36,160、视频15,512；保守去重后51,620，已确认冗余52。两组加总一致。实际点击“刷新统计”后显示时间从10:45更新到10:47，数量保持一致。当前视频精确摘要覆盖为0/15,512，因此不能将“视频确认冗余0”解释为已经证明没有重复视频。

CUA 此后重新连接该实例持续超时；采样显示 App 主线程处于事件等待，没有发现刷新查询卡死。日常 App 的逐项视频操作不冒称本轮已验。当前总览截图仅保存在临时文件：`/var/folders/74/m3grr2ds6d78rxzq4c05_l8h0000gn/T/codex-shot-2026-10-16_10-49-29.png`。

## 安全、限制与复跑

- 实际日常 App 只执行目录聚合统计刷新；未对真实来源执行扫描、元数据回填、完整摘要、AI、多帧、标签、回收或下载操作。
- 文件读写与回收恢复发生在本任务创建的合成临时根；没有读取受保护媒体内容、没有真实源端写入、没有真实 iCloud / 付费模型 / 用户媒体外传。
- 真实文件夹/Photos完整视频路线、真实iCloud、实体设备、付费模型、发布安装均为 NOT_RUN。Web/iOS/Companion 专属验收不属于本目标。
- CUA 的确认弹窗读取故障仍存在；本次操作通过用户协助完成，不属于无人值守UI自动化通过。
- 普通包装器及最短路线见[Mac人工验收](VIDEO-MAC-ACCEPTANCE.md)。需要真实 AppKit 焦点的合成验收可运行 `scripts/prepare_native_video_acceptance.py`，用 CUA 或人工打开其返回的临时 `.app`；只在观察满足要求后创建该证据根的 `finish`。

已有失败日志（包括旧宿主未观察到焦点、首次诊断编译错误和依赖不完整的启动原型）均保留。它们没有被计为通过；最终通过证据分别列于上表。
