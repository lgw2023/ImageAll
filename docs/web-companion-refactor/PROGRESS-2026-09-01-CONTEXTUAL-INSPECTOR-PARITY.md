# 图库上下文检视器功能对齐

日期：2026-09-01

## 结论

本轮纠正了一个被矩阵遗漏的高频假对齐：Mac 图库右侧检视器会跟随当前选择显示照片属性、
标签和操作，而 Web 工作区右侧面板此前只有会话信息，并保留“所选照片属性将在这里显示”的
占位文案。现在图库选择会发布独立的上下文检视器；它沿用 Helios Web 视觉，不复制 Mac 外观，
但补齐了同一条“选择照片 → 检查信息 → 原位处理”的用户闭环。

## 交付范围

- 单选时从 `GET /v1/assets/:id` 读取并显示文件名、来源、相对位置、媒体类型、格式、尺寸、
  视频时长、文件大小、拍摄时间、修改时间和可用状态；无需先打开 Lightbox。
- 多选时冻结当前 asset IDs，显示所选数量和来源数量；检视器内可收藏/取消收藏、删除、清空
  选择，单选时还可打开大图。
- 标签按 Host `tag-groups` 顺序分组，聚合展示已确认、已拒绝、未决定或状态不一致；左键确认、
  右键清除、`X` 拒绝、`Backspace/Delete` 清除。
- 标签决定失败后保留相同 operation ID 原位重试；成功或 Host 调和后把焦点恢复到原标签，
  不让键盘工作流中断。
- 路由只在检视器真正打开时挂载内容，避免关闭面板在隐藏 DOM 中复制全局状态或 live region。
  桌面关闭后焦点返回顶栏触发器；移动端抽屉保持选择，上下文按钮最小触控高度为 44 px。

## TDD 证据

1. 先写单图元数据流程，测试因找不到“照片信息”失败；接入路由上下文后转绿。
2. 再写冻结多选标签流程，测试因找不到“2 项选择”失败；实现 Host 分组和批量决定后转绿。
3. 焦点回归首先暴露原生 `disabled` 会丢失焦点；改为语义禁用并在 Host 调和后显式恢复。
4. 503 重试首先因无重试入口失败；补齐稳定 operation ID 后转绿。
5. 响应式/可访问性测试先后暴露标签对比度不足、移动按钮不足 44 px、桌面关闭按钮被旧样式
   隐藏；修正后桌面与移动端 axe、无溢出和焦点断言全部通过。
6. 最后补写冻结选择收藏、删除、清空流程，先红后绿，并复用现有删除确认边界。

## 验证结果

- `npm run format:check`：通过。
- `npm run lint`：通过，0 warning。
- `npm run typecheck`：通过。
- `npm run test -- --run`：11 个文件、31/31 tests 通过。
- `npm run test:e2e`：168 passed、6 skipped、0 failed；新检视器 5 个工作流在桌面和移动端
  共执行 10 次。
- 10k 合成图库：fixture SHA-256
  `0db043e9e228ff18deaa183a280c69b6ed05257bdbc1c388608e27042f8c34cc`；首屏交互
  945 ms、781 个 DOM 节点、36 张可见卡片、选择 p95 18.2 ms、查看器 p95 124.9 ms、
  0 long task、滚动锚点漂移 0。
- `npm run build`：通过；`asset-manifest.json` SHA-256
  `7c2ad07f190fc0d43975c32b5ff243773e83c2924c0290c4ebfb4dd52270e1fa`。
- `xcodebuild ... build-for-testing`：退出码 0；App bundle 的 `WebCompanionV2` 与源资源 `diff -qr`
  无差异。构建仍输出仓库既有 Swift 弃用、未使用结果和并发隔离 warning，本轮未新增 Swift 源码。

## 截图

- 桌面：`evidence/gallery/imageall-react-context-inspector-chromium-desktop.png`
- 移动：`evidence/gallery/imageall-react-context-inspector-chromium-mobile.png`

## 证据边界

- 浏览器测试只使用合成 Host、合成资产和标签树；未读取、遍历或写入 HDD2 的受保护真实照片。
- 本轮证明 UI 投影、请求范围、重试、焦点和响应式布局，不证明真实照片元数据准确性、真实 Host
  延迟、大标签库性能或破坏性文件操作结果。
- 自动 axe 不能替代人工 VoiceOver 听读；后者仍属于发布前人工检查。
