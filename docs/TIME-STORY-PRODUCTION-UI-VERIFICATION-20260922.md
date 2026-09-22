# 时光故事制作入口验证 · 2026-09-22

## 已完成

- 两轮 Debug 构建成功，最终日志位于 `/Volumes/SSD1/ImageAll-artifacts/story-production-ui-20260922/build-final.log`。
- 日常 App 更新至 `/Volumes/SSD1/ImageAll-Daily/ImageAll.app`；与 Xcode 日常构建路径的 debug dylib SHA-256 均为 `0a58e3931ceea511e6d9e2e0f4c90d9fe159878612daf8008092c6cdceb98eb1`。日常 App 通过 `codesign --verify --deep --strict`。
- 更新前通过 UI 保存当前故事，收到“故事项目已保存”。旧 App 保留在 `/Volumes/SSD1/ImageAll-artifacts/story-production-ui-20260922/ImageAll-before.app`。
- 同一日常二进制使用 `IMAGEALL_TIME_STORY_UI_VERIFICATION=1`、`IMAGEALL_ATELIER_SYNTHETIC=1`、`IMAGEALL_TEST_HOST_ISOLATION=1` 启动合成工作区。完成创建自由编排、加入一张合成图片；UI 显示新“制作视频…”入口，导出按钮在有镜头后启用。
- 本轮只修改 UI 与说明文档，未修改数据协议、渲染器、Photos API、来源文件写入逻辑。未提交真实素材创作、导出或云端任务。

## 初次验收中断与异常（历史记录）

- 首次合成启动指定了沙箱外产物目录，被 sandbox 拒绝并触发现有 fixture 的 try!；改用已有 fixture 默认的容器临时目录后成功。UI 工具在进程退出后曾自动打开正常启动窗口，随后关闭并重新进入合成模式。
- 点击“制作视频…”时，Computer Use 返回 `Sky Computer Use native pipe closed before response`。重试和重置工具会话后仍相同。App 进程仍在、合成日志未报错，但不能据此认定面板交互和布局已经验收。
- 当时三模式切换、反复开关、画幅选择恢复、导出子菜单、停用服务状态以及面板截图均为 NOT_RUN / 未完成现场确认；下方续验已补齐这些项目。源码已检查条件分支与请求画幅绑定；这些静态检查不替代交互验收。
- 已结束本轮合成进程，并通过正常应用启动方式恢复日常 App；工具故障导致未能读取恢复后的窗口内容。

## 数据边界

UI 自动化仅创建合成像素与临时 catalog，不遍历受保护 Photos 包或 HDD2 来源；现有真实故事仅执行更新前保存。未对源照片执行删除、移动、改名、覆盖、sidecar 写入或下载；本轮没有对真实来源做完整扫描或哈希验证，不把它描述为已完成源端完整性审计。


## 续验完成 · 2026-09-22 16:56

用户要求继续完成验收，并明确授权使用 macOS 辅助功能脚本替代故障的界面控制工具；点击操作仅针对合成故事。

### 控制工具故障归因

再次点击面板后出现同样断连。`SkyComputerUseService-2026-09-22-164624.ips` 记录控制服务因 `Array.remove(at:)` 断言失败退出；ImageAll 进程仍运行，截图确认面板正常显示。该证据指向控制服务故障，不能据此推断具体是何种 AX 结构触发。授权后通过独立 Swift AX 脚本继续验收，无需修改 App。

### 实测结果

所有操作使用日常安装路径的同一二进制和已有合成入口，22 张合成候选、选入 1 张。记录的 12 项 UI 状态断言全部通过：

- 顶部“制作视频…”实际打开独立面板，截图核对内容与分组清晰。
- 当前编排切换竖屏，可编辑创作沿用竖屏，提交按钮相应显示“生成可编辑方案 · 竖屏 9:16”。
- 自由场景仅显示竖屏及限制说明，不出现可选横屏；切回当前编排仍保留先前竖屏选择。
- 点击“完成”后 AXSheet 消失；再次打开后 AXSheet 重现，画幅保持不变。
- “连接选项”展开后出现选择任务目录与检查连接。
- 导出菜单分组正确；故事包子菜单展开后可见横屏 16:9、竖屏 9:16。
- 用进程参数 `-OpenMontage.IntegrationEnabled.v1 NO` 临时覆盖停用状态，未更改持久偏好。当前编排、可编辑创作、自由场景提交按钮均禁用，直接导出按钮仍启用。
- 在停用状态点击直接导出，系统 MP4 保存窗口实际出现；取消后返回工作区，未生成视频文件。AXPress 因同步 runModal 返回 -25204，但随后读到的保存窗口与成功取消确认操作确已发生。
- 从右侧“创作”快捷入口再次打开面板成功。
- 三张合成面板截图已检查；内容可滚动，固定“完成”按钮可触达。

证据目录：`/Volumes/SSD1/ImageAll-artifacts/story-production-ui-20260922/`。包含 `ax-*.txt`、`acceptance-checks.json`（12/12 true）、`production-panel.png`、`atelier-panel.png`、`disabled-panel.png` 和辅助验证脚本。AX 记录包括系统最近文件菜单，保留在本机产物目录，不提交仓库。

### 日常恢复及结论

已退出合成进程，以正常方式重新启动日常 App。退出后立即启动曾返回 LaunchServices -600，待退出完成后重试成功。日常二进制 hash 与前次发布一致，严格签名复核通过；本轮无代码变更、不需要重新构建或替换 App。

本次补齐的是按钮、画幅、菜单、禁用条件和布局验收。没有点击创作提交、启动执行器、真实导出或真实照片写操作；不将 UI 验收等同于新视频渲染交付。
