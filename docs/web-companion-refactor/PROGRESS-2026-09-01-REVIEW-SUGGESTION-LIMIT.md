# Review 共享每标签上限纵切片

日期：2026-09-01
状态：本纵切片已实现并完成合成验收；审查概览仍为 `in-progress`

## 产品与契约判断

Mac `ReviewOverviewHeader` 把“每标签上限”作为审核主路径控件，范围 1…10000、步长 50；个人抽检、
按标签个人建议、Feature Print 和标准模型共享同一工作区偏好。新版 React 已能在设置页读写
`maxPendingSuggestionsPerTag`，但 Review 概览没有入口，导致用户必须离开审核现场才能调整。

本轮直接复用现有 `/v1/settings/general` GET/PUT 与 `general-settings` Query 缓存，不新增 Host 协议。
写入只提交这一个字段与新的 operation ID；Host 响应成功后才替换显示值，失败不得乐观假成功。
视觉继续使用 Nocturne 的发光刻度控件，不复制 Mac Stepper 外观。

## 完成的闭环

- Review 概览顶栏新增可访问的“每标签上限”组合控件，±50 并在 1…10000 内钳制。
- 请求进行时禁用两个动作；Host 成功响应后更新共享设置缓存，进入队列再返回仍显示权威值。
- Host 503 原位展示可理解错误，保留原值；再次点击可重试，不离开当前来源范围或审查上下文。
- 旧 Host 未投影该可写字段时显示“只读”并禁用动作，不伪造可写能力。
- 桌面控件保持紧凑右对齐；390px 下扩展为整行大触控目标，不产生横向溢出。

## TDD、视觉与边界证据

先对上一版生产构建新增行为级 RED：Review 页面不存在“每标签上限”组合控件。实现后同一用例验证
初值 200、首次 PUT 503 后仍为 200、重试请求只写 250、Host 响应后显示 250，以及进入审查队列再
返回仍保持 250；桌面与 390px 均执行 axe WCAG 2.1 A/AA。

- Review/curation 聚焦回归：18 个桌面与移动用例通过。
- `format:check`、lint、typecheck、31 个 Vitest 单元/契约测试与生产构建通过。
- 全量 Playwright：104 项中 100 通过、4 项按项目配置跳过、0 失败。
- Mac `build-for-testing` 通过；源码静态目录与构建 App 内嵌 `WebCompanionV2` 递归 diff 为空，
  `asset-manifest.json` SHA-256 为
  `ce4e64ec65ef327a2fcf2142de18108aa3158fa17dd5fdcdc03f4b82a5cb12ac`。
- 视觉证据：
  - `evidence/curation/imageall-react-review-limit-chromium-desktop.png`
  - `evidence/curation/imageall-react-review-limit-chromium-mobile.png`

自动化只使用合成设置、标签、来源与队列；没有读取或遍历 `/Volumes/HDD2`、真实 Photos Library、
真实 iCloud，也没有启动生产 Host。证据证明 Web 与 Host 设置契约及界面连续性，不证明真实四条
建议生成路径已经在生产数据上采用这个值。

## 剩余边界

审查概览仍缺本地模型服务状态、标准/个人模型生成与暂停/恢复/取消控制，以及按标签组折叠。后两项
分别需要面向 Review 的统一任务投影和 overview 标签组映射，不能用已有 Training 页面或前端临时
分组冒充完成。
