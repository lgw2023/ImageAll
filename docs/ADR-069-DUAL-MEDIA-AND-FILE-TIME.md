# ADR-069：媒体内嵌时间与文件修改时间分离

- 状态：Accepted
- 日期：2026-09-03
- 范围：目录库、文件夹扫描、Mac 图库、Web Companion 图库

## 背景

照片在复制、导出或跨卷整理后，文件系统修改时间可能变化，而照片内部的拍摄时间仍保持不变。
ImageAll 原有 `media_created_at_ms` 保存可靠的媒体拍摄时间，`file_fingerprint.modified_at_ns`
保存文件身份校验所需的修改时间，但图库查询和界面没有把这两类事实作为独立能力提供；原有
“最新/最早”使用 `media_created_at_ms ?? media_modified_at_ms`，用户无法明确选择排序依据。

## 决策

1. `media_created_at_ms` 继续表示媒体时间：文件夹媒体来自带明确时区的 EXIF/容器时间，Photos
   来自 PhotoKit `creationDate`。无时区 EXIF 不静默按本机时区解释。
2. `asset.file_modified_at_ms` 明确保存普通文件夹媒体的文件系统修改时间。V039 从既有
   `file_fingerprint.modified_at_ns` 回填；以后每次文件夹 reconcile 与 fingerprint 同批更新。
   Photos locator 没有稳定原文件路径，因此该字段为 `NULL`。
3. 原有“最新优先/最早优先”及其键集游标保持兼容。新增四种独立排序：媒体内嵌时间新到旧、
   媒体内嵌时间旧到新、文件修改时间新到旧、文件修改时间旧到新；未知值一律后置。
4. 四种新排序使用各自的 partial ascending/descending index 和稳定 Asset ID 次排序；分页不得使用
   `OFFSET`，不得重复或漏项。
5. Mac 与 Web Companion 的排序入口、悬停信息和详情面板同时展示两类时间。旧 Host/客户端缺少
   `fileModifiedAtMs` 时按空值兼容。
6. 时间展示和排序是只读目录能力，不授权修改来源。任何真实照片时间修复必须使用单独的写入确认、
   回滚账本和源端验证；Apple Photos 包不提供直接文件时间修复。

## 验证

- V039 在合成旧库中回填文件修改时间并建立四个查询索引，重复打开保持幂等。
- 文件夹 reconcile 的新增、保留和移动路径同时写入媒体内嵌时间与文件修改时间。
- 四种新排序完整拉取与两项键集分页顺序一致，未知值后置，游标不能跨排序复用。
- Mac 构建、RemoteProtocol、Web typecheck/build 通过；测试只使用临时目录和合成媒体。
