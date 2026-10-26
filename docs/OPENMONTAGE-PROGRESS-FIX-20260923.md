# OpenMontage 0% 故障修复 · 2026-09-23

## 根因与决策

字体扩展更新了 StoryRenderPackage Schema，但任务协议的 task / completion 两处 storyPackage.schemaSHA256 常量仍固定为上游旧值。执行器在 intake 以 COMPLETION_INVALID 拒绝；尚未验证身份的拒绝记录使用全零 submission digest。App 将该摘要判为协议错误，保留旧的 waitingForExecutor 快照，造成长期显示 0%。

构建补丁同步更新两处精确常量、协议 lock 及 Swift 能力握手哈希。补丁只接受已审阅的上游/扩展 Schema 字节，未知修改拒绝打包，不放宽为任意哈希。

App 在任务 ID、项目 ID、修订与终态标记全部匹配后，仅允许 rejected + terminal + intake error + non-retryable 的全零摘要记录进入失败状态；不允许其报告成功或授权输出。COMPLETION_INVALID 显示“尚未开始渲染”的明确说明。

## 验证

- Python 协议回归通过：两种 envelope 接受扩展哈希、拒绝旧哈希；重复补丁稳定，lock / Swift 哈希一致，未知 Schema 拒绝。
- 无生产 App 宿主的直接 XCTest：拒绝状态与零摘要成功拒绝、取消/恢复/修订隔离，2/2 通过。
- Debug build 与 build-for-testing 通过。
- 原冻结任务通过完整 verify_submission，包括文件哈希与清单摘要。

## 本次恢复范围

保留原拒绝任务与状态。仅把用户当前任务的已有 submission 复制为一个新任务，更新任务身份、提交时间与清单；故事及派生素材保持不变。执行器恢复脚本限定只处理新任务，不重放历史队列、不调用模型。结果留在既有 daily-tasks/runs 应用任务目录。

没有访问受保护照片源目录或 photoslibrary 包，没有新增下载或源端写入。回归使用合成 fixture；本次真实制作只读取用户已发布到任务目录的派生副本。测试、旧 App 备份与恢复日志位于 `/Volumes/SSD1/ImageAll-artifacts/progress-fix-20260923/`。已有混合工作区改动保留，未 push。

## 恢复结果

恢复任务 `imageall-300698e2-f448-499a-b582-67776b898ff7` 实际经历 rendering → verification → succeeded，进度 100%。成片 H.264、1920×1080、30 fps、725 帧、24.166667 秒；原项目无配乐，因此无音轨。执行器媒体验证、输出 SHA-256 对照及 FFmpeg 全片解码通过。

日常 `/Volumes/SSD1/ImageAll-Daily/ImageAll.app` 更新并通过 strict/deep 签名校验，主动态库与已构建版本哈希一致。正常启动并打开已保存的草莓音乐节故事成功；随后 CUA native pipe 连续断开，最终“制作完成”面板的可见验收未完成，不把后台成功冒充屏幕验收。
