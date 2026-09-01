# Review 单图 iCloud 预览恢复纵切片

日期：2026-09-01
状态：本纵切片已实现并完成合成验收；审查概览仍为 `in-progress`

## 产品与契约判断

新版 Review 连续单图原先直接把预览端点交给 `<img>`，因此 Host 返回稳定的
`409 cloud preview required` 时只会留下破图，无法进入 Mac 已有的显式云预览恢复流程。
本轮不增加新 Host 协议，而是复用 Gallery 已验证的受保护 Blob 预览与云预览生命周期；视觉继续使用
Nocturne 数字暗房语言，不复制 Mac 外观。

只有用户明确点击按钮才可启动下载。切换审核项、关闭单图或卸载组件时必须取消仍在进行的操作；
完成后只刷新当前预览，不得重置审核队列、当前项、选择或呈现上下文。旧 Host 继续由共享生命周期保留
同步端点回退。

## 完成的闭环

- Review 单图通过统一认证客户端读取有界 Blob 预览，并在切图、关闭或刷新后回收对象 URL。
- 409 原位显示“从 iCloud 获取预览”；启动后展示 Host 权威进度与取消动作，取消或失败后可重试。
- 切到下一项会取消当前 operation；返回同一云端项目重试时使用新 operation ID，避免陈旧结果覆盖。
- Host 完成后原位重取普通预览，标题、队列位置和当前卡片保持不变。
- `Space` / `Enter` 在恢复按钮上保留浏览器原生激活语义；P/X/U 和方向键仍维持连续审核快捷键。

## TDD、视觉与边界证据

先对上一版生产构建新增行为级 RED：云端审核项目没有“从 iCloud 获取预览”按钮。实现后同一用例在
桌面与 390px 移动视口验证点击前零 operation、42% 进度、切图取消、返回后新 operation ID、重试
完成与队列位置不丢失，并执行 axe WCAG 2.1 A/AA 检查。

- Review/curation 聚焦回归：16 个桌面与移动用例通过。
- `format:check`、lint、typecheck、31 个 Vitest 单元/契约测试与生产构建通过。
- 全量 Playwright：102 项中 98 通过、4 项按项目配置跳过、0 失败。
- Mac `build-for-testing` 通过；源码静态目录与构建 App 内嵌 `WebCompanionV2` 递归 diff 为空，
  `asset-manifest.json` SHA-256 为
  `b4cf2630fa54bdbf2ec3500292cbafbf86e7cdd93007f388298805cbf5ead2cd`。
- 视觉证据：
  - `evidence/curation/imageall-react-review-cloud-preview-chromium-desktop.png`
  - `evidence/curation/imageall-react-review-cloud-preview-chromium-mobile.png`

自动化仅使用虚构 UUID、合成 SVG 与模拟 Host 409/生命周期响应；没有读取或遍历
`/Volumes/HDD2`、真实 Photos Library 或真实 iCloud，也没有启动生产 Host。因此截图证明布局与状态
连续性，不证明真实 iCloud 下载吞吐、PhotoKit 行为、预览解码或色彩正确性。

## 剩余边界

审查队列这条矩阵行已补齐显式云端恢复；整个 Review 仍未完成。每标签上限已由后续
[Review 共享上限纵切片](PROGRESS-2026-09-01-REVIEW-SUGGESTION-LIMIT.md)补齐；审查概览仍缺本地模型
状态、生成/暂停/恢复/取消任务控制和分组折叠，必须作为后续纵切片单独实现与验收。
