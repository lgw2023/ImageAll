# 时光故事第三阶段：本地 OpenMontage 双边联调记录

> 后续状态（2026-09-20）：本页保留当时的短片、竖屏及失败路径联调记录。随后从日常安装版 App 提交的约 60 秒横屏任务已完成联合验收；唯一权威结论及新证据见
> `/Volumes/SSD1/ImageAll-Story-Interop/phase3/joint-acceptance-20260920-101819/JOINT_ACCEPTANCE.md`。
> 本页的历史任务与当时尚未覆盖的范围不回填为已完成。

- 日期：2026-09-20
- 工作目录：`/Volumes/SSD1/ImageAll`，`main`，仅本地提交，未 push
- 数据边界：只用代码生成的合成图片和音频；未访问 `/Volumes/HDD2` 的受保护真实照片，未对真实来源执行写入、删除、移动或云端下载
- 任务根：`/Volumes/SSD1/ImageAll-Story-Interop/phase3/task-root`，由日常 App 的系统目录选择器授权；不是生产代码中的固定路径

## 版本、安装与来源

日常 App 安装前的 `eabd170f…` 是 `Contents/MacOS/ImageAll` 启动文件哈希，第二阶段报告的
`bc309be0…` 是同一 App 内 `ImageAll.debug.dylib` 哈希，严格签名校验通过；两者不构成损坏证据。
对应的原安装版保留在
`/Volumes/SSD1/ImageAll-Daily/ImageAll-before-story-phase3-20260919-0114.app`。
安装目录本身没有可反向证明源码提交的签名 provenance 清单，不能仅凭哈希证明当时的精确提交。

最终日常 App：`/Volumes/SSD1/ImageAll-Daily/ImageAll.app`。从应用源码提交
`f550d351` 签名构建并在安装前验证，安装后重新登记：

| 身份 | SHA-256 / 值 |
| --- | --- |
| `Contents/MacOS/ImageAll` | `a70334ec7cf97d632536f9661c252468f97fc3e177e582acd3da37162248f32b` |
| `Contents/MacOS/ImageAll.debug.dylib` | `a9b376c0be2be4c401dd92739b8ba5c1064c63b8bb6956f59a400e28edea7753` |
| 签名 | Apple Development，Team `962554J6D3`；`codesign --verify --deep --strict` 通过 |
| 权限 | App Sandbox、app-scoped bookmark、用户选择文件夹读写和原有 Photos 权限；与安装前授权项一致 |

每次替换前保留可恢复副本；最近两份为
`/Volumes/SSD1/ImageAll-Daily/ImageAll-before-story-phase3-frame-fix-20260920.app` 和
`/Volumes/SSD1/ImageAll-Daily/ImageAll-before-story-phase3-save-fix-20260920.app`。

ImageAll 相关本地提交：`b2a87f25`（任务接入）、`62d74c29`（小数秒时间戳）、
`cf3603bc`（真实视频样本数与自然语言状态）、`f550d351`（安全另存）。
OpenMontage 协议 v1.1 固定提交 `1dbf43f`，任务 Schema SHA-256 为
`da49966ac4b60c9a1b597768ff898eadf1c9c063bb91e95e4bb9754e5802e912`；
故事内容仍使用 StoryRenderPackage v0.1，Schema SHA-256 为
`884a6fed3eb4d8cf3b37c450b8a9a4e2d21782220532a66d21dccdf8fe696841`。
真实联调使用的 OpenMontage 执行器包含 `90fd31c` 的受限绝对产物路径修复；协议字段未改。

## 测试与真实任务

ImageAll 聚焦合成测试：
`/Volumes/SSD1/ImageAll-Story-Interop/phase3/TimeStoryFeatureTests-save-directory-fixed.xcresult`，
16 通过、0 失败、1 个需显式启用的第二阶段交付生成器跳过。最终 Debug App 构建和严格签名校验通过。
执行器 `check` 全部就绪，协议 1.1，执行器 1.1.0，首版最大并发 1。

| taskID 后缀 | 终态 | 证据 |
| --- | --- | --- |
| `b088899c-2f2e-4dec-898a-edfc40faaa03` | failed | 首次真实渲染生成视频，但旧执行器拒绝任务内适配器的绝对产物路径；状态为 `RESULT_VERIFICATION_FAILED`。失败任务保留，未原 ID 重试。 |
| `6798e7b2-1848-46ac-ac80-f5637390892d` | cancelled | App 写入该 taskID 的 `requests/cancel.json`；执行器终态 cancelled，无 `result.json`，App 未显示成功。项目修订号与前任务不同。 |
| `79f6e905-5dd2-49d1-a817-be328199dcc2` | succeeded | 横屏 1920×1080、30 fps、775 帧、25.833333 秒；执行器结果与 `ffprobe -count_frames` 一致。App 重开后恢复同一 taskID，严格核验并用“打开成片”在 QuickTime 实际播放。 |
| `871da2a9-2160-4f87-a7d8-1a4be7220af7` | succeeded | 竖屏 1080×1920、30 fps、1750 帧、58.333333 秒；结果、`ffprobe`、App 成功界面一致，在 QuickTime 播放并由 Finder 精确选中。 |
| `f4fae979-4a7d-4f1b-bfc6-3d74f5a2ab2e` | succeeded | 从最终安装版（启动文件 SHA-256 `a70334ec…`）直接提交新的横屏短片；1920×1080、30 fps、775 帧、25.833333 秒；App 验证后在 QuickTime 打开并播放。 |

成功结果相对任务根的路径由各任务的 `state/result.json` 给出，具体为：

```text
runs/imageall-79f6e905-5dd2-49d1-a817-be328199dcc2/story-9af645a8fef33e6d34085cc6-rsha256-ad72df0ff521c174df2439f6fd42d9c05ea1cf8a9f70281c425e47c86f9ce870-imageall-79f6e905-5dd2-49d1-a817-be328199dcc2/renders/story-1920x1080.mp4
runs/imageall-871da2a9-2160-4f87-a7d8-1a4be7220af7/story-9af645a8fef33e6d34085cc6-rsha256-bbb27069edec31f4e27a47711ba7d1e84490016db1d99c3c75fc2841ae180266-imageall-871da2a9-2160-4f87-a7d8-1a4be7220af7/renders/story-1080x1920.mp4
runs/imageall-f4fae979-4a7d-4f1b-bfc6-3d74f5a2ab2e/story-9af645a8fef33e6d34085cc6-rsha256-7e10b62aeb0be66508d4a37080f2c653ab4c92aa76fa518d9c096a5ff4fa3465-imageall-f4fae979-4a7d-4f1b-bfc6-3d74f5a2ab2e/renders/story-1920x1080.mp4
```

第二条竖屏原片 SHA-256 为
`a60852cb4d7bf6233860021bda1955d9030cfe17452483bcc249c0aa4ba42e18`。
最终安装版新短片 SHA-256 为
`1a08fa7d1a0a578a8a00f4e39721ccb4c7297fb68c5f9714cbfb184d539ebb7a`。
通过最终安装版的目录选择器另存为
`/Volumes/SSD1/ImageAll-Story-Interop/phase3/ImageAll-portrait-verified-copy.mp4`，
副本大小 1,588,560 字节且哈希相同。同名再次另存被明确拒绝；原文件哈希不变，目标目录无残留暂存文件。

恢复、离线和修订隔离：运行中关闭日常 App 后重开，只重新关联已有 taskID，没有多发布任务；
停止执行器后设置显示未连接，手动尝试制作被拒绝，任务总数不变。58 秒任务运行中编辑了标题，
编辑器显示新标题，而已发布 `story.json` 和 QuickTime 成片保留提交时标题，完成后未覆盖当前编辑。
旧横屏成功任务的 `state/result.json` 哈希在新竖屏任务完成前后保持
`0109c8c682dfb2203af7184f87cd7db92d3a2037fe69928001bbc5902eb768b3`。

## 实际联调发现与界限

1. OpenMontage 的首个真实任务在产物路径验证处失败；修复 `90fd31c` 后新 taskID 成功，
   原失败记录没有被篡改或误报。
2. AVFoundation 读取短片时返回 779 次缓冲区回调，但其中 4 次为零样本标记；实际视频是 775 帧。
   ImageAll 现在累计真实视频样本数，仍要求与任务结果及故事包总帧数一致。
3. 初版另存仅由系统保存面板授权单个目标文件，却试图在父目录创建暂存文件；真实沙盒拒绝。
   现改为系统文件夹授权、同目录暂存/哈希核对/原子发布，同名拒绝覆盖，并已从最终安装版复验。

本轮未用真实“板栗”素材，未验证真实图库选片质量，也未进行非合成素材的人工审片。OpenMontage
继续作为用户独立启动的本地执行器；ImageAll 不打包或启动其运行时，不关闭沙盒，不扩大 Photos 权限。
依赖、AGPL/Remotion/FFmpeg、字体与音乐等生产分发评审仍按 OpenMontage 的依赖与许可文件单独处理。
执行器异常强制终止的现场故障注入未做；离线/停止状态及模拟中断路径已经验证。
