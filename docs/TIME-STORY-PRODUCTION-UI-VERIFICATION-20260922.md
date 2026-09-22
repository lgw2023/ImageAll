# 时光故事制作入口验证 · 2026-09-22

## 已完成

- 两轮 Debug 构建成功，最终日志位于 `/Volumes/SSD1/ImageAll-artifacts/story-production-ui-20260922/build-final.log`。
- 日常 App 更新至 `/Volumes/SSD1/ImageAll-Daily/ImageAll.app`；与 Xcode 日常构建路径的 debug dylib SHA-256 均为 `0a58e3931ceea511e6d9e2e0f4c90d9fe159878612daf8008092c6cdceb98eb1`。日常 App 通过 `codesign --verify --deep --strict`。
- 更新前通过 UI 保存当前故事，收到“故事项目已保存”。旧 App 保留在 `/Volumes/SSD1/ImageAll-artifacts/story-production-ui-20260922/ImageAll-before.app`。
- 同一日常二进制使用 `IMAGEALL_TIME_STORY_UI_VERIFICATION=1`、`IMAGEALL_ATELIER_SYNTHETIC=1`、`IMAGEALL_TEST_HOST_ISOLATION=1` 启动合成工作区。完成创建自由编排、加入一张合成图片；UI 显示新“制作视频…”入口，导出按钮在有镜头后启用。
- 本轮只修改 UI 与说明文档，未修改数据协议、渲染器、Photos API、来源文件写入逻辑。未提交真实素材创作、导出或云端任务。

## 未完成与异常

- 首次合成启动指定了沙箱外产物目录，被 sandbox 拒绝并触发现有 fixture 的 try!；改用已有 fixture 默认的容器临时目录后成功。UI 工具在进程退出后曾自动打开正常启动窗口，随后关闭并重新进入合成模式。
- 点击“制作视频…”时，Computer Use 返回 `Sky Computer Use native pipe closed before response`。重试和重置工具会话后仍相同。App 进程仍在、合成日志未报错，但不能据此认定面板交互和布局已经验收。
- 因此三模式切换、反复开关、画幅选择恢复、导出子菜单、停用服务状态以及面板截图均为 NOT_RUN / 未完成现场确认。源码已检查条件分支与请求画幅绑定；这些静态检查不替代交互验收。
- 已结束本轮合成进程，并通过正常应用启动方式恢复日常 App；工具故障导致未能读取恢复后的窗口内容。

## 数据边界

UI 自动化仅创建合成像素与临时 catalog，不遍历受保护 Photos 包或 HDD2 来源；现有真实故事仅执行更新前保存。未对源照片执行删除、移动、改名、覆盖、sidecar 写入或下载；本轮没有对真实来源做完整扫描或哈希验证，不把它描述为已完成源端完整性审计。
