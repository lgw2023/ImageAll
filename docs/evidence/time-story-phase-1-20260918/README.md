# 时光故事第一阶段验收证据（2026-09-18）

## 验证边界

- 全部自动化、成片和界面运行证据均使用测试创建的临时目录与合成图片/音频。
- 未读取 `/Volumes/HDD2/Photos Library.photoslibrary` 或 `/Volumes/HDD2` 下四位年份目录，未触发真实照片下载，未写入、移动、重命名或删除任何源照片。
- 本证据只证明原生闭环和确定性回归；不声称“板栗”真实图库已验证，也不代表用户已经认可自动选片质量。

一次收尾重跑曾发现 Xcode 不会把 shell 中的 `IMAGEALL_TEST_HOST_ISOLATION` 自动传给宿主 App；该次运行已中断。它启动过生产 catalog 启动流程，但测试没有请求 PhotoKit 素材、没有读取上述受保护路径、没有执行真实照片导出，也没有源端照片写入。随后已将 XCTest 自动隔离内建到 composition root，最终 8/8 通过记录来自修复后的临时目录宿主。

## 构建与自动化

- 签名 Debug 构建：`xcodebuild -project ImageAll.xcodeproj -scheme ImageAll -configuration Debug build`，结果 `BUILD SUCCEEDED`。
- 聚焦测试：`xcodebuild -project ImageAll.xcodeproj -scheme ImageAll -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData-time-story test -only-testing:ImageAllTests/TimeStoryFeatureTests`。XCTest 宿主由 composition root 自动切到临时目录且不构造图库工作区。
- 结果：8/8 通过；结果包：`/Volumes/SSD1/ImageAll/.derivedData-time-story/Logs/Test/Test-ImageAll-2026.09.18_11-17-04-+0800.xcresult`。
- 覆盖：完整分页、早期稀疏/近期密集、A → B → A、无 GPS 早期素材、未知时间待确认、跨时期相似素材、重新生成编辑保持、原子保存/重开、素材缺失或版本变化定位、转场时间线、无音乐/有音乐导出、取消不覆盖既有成片。

## 成片

| 文件 | SHA-256 | 结果 |
| --- | --- | --- |
| `synthetic-silent.mp4` | `57ef6cebde10a98222445da47a6df3b5c932983076def56d99dcc92c09fd78cb` | H.264、1920×1080、30 fps、2.566667 秒、无音轨 |
| `synthetic-with-music.mp4` | `060ce3b52836da6273ef0396c533e7c9eaf9a80428bb422bd85e5e40d94e392e` | H.264 + AAC、1920×1080、30 fps、2.566667 秒 |

`ffprobe-silent.json` 与 `ffprobe-with-music.json` 保存机器可读的流、分辨率、帧率和时长结果。
`frame-opening.png`、`frame-transition.png`、`frame-middle.png`、`frame-ending.png` 及
`frame-contact-sheet.png` 是对片头、转场附近、中段、片尾的抽帧。人工抽查确认：中文字幕可读；横图和竖图方向正确；竖图保持完整画面并使用背景填充；片头、中段、片尾无意外黑帧；转场帧包含预期淡化叠加。

## 已安装日常 App 的界面运行证据

- 最终安装位置：`/Volumes/SSD1/ImageAll-Daily/ImageAll.app`。
- 最终可执行文件 SHA-256：`ec201e28c5f8793da668a775209271778ef40260d0a8f547cc9bb5ec1bc3360b`。
- `codesign --verify --deep --strict` 通过；签名为 Apple Development，签名时间 2026-09-18 11:26:45；安装包不包含测试插件。
- 在该已安装 App 上用隔离临时根和合成标签启动，从“标签 合成主体” → “管理” → “创建时光故事…”进入实际共享入口。
- 工作区实际显示：5 张匹配、4 张可靠时间、1 张时间未知、2 个地点、1 张地点未确认、0 张不可用；可靠拍摄时间覆盖 2018-01-01 至 2025-01-01，并明确显示 1 张无地点素材；章节保留上海 → 杭州 → 上海；可见时间线预览、选片理由、替换、锁定、移除、时长、保存、重新生成、配乐和导出控件。
- 验证模式在窗口内明确显示“未读取真实照片”；退出后已关闭验证进程。

可恢复版本：

- 原始日常 App：`/Volumes/SSD1/ImageAll-Daily/ImageAll-before-time-story-20260918-1059.app`。
- 最终转场修复安装前：`/Volumes/SSD1/ImageAll-Daily/ImageAll-time-story-before-transition-fix-20260918-1110.app`。
- 最终就绪摘要/测试宿主安全修复安装前：`/Volumes/SSD1/ImageAll-Daily/ImageAll-time-story-before-readiness-safety-20260918-1127.app`。

## 尚未验证

- 未对真实“板栗”标签执行只读候选生成、人工选片质量判断或真实媒体导出；这需要项目所有者另行明确授权具体只读人工验证范围。
- 未将合成算法结果解释为真实素材的叙事质量认可。
