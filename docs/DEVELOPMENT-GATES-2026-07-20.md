# ImageAll 后续开发门审计（2026-07-20）

## 1. 实时基线

- 分支：`main`
- 审计开工 HEAD：`3b6a276fada7a059d2ee48de2c693f68cecf5dad`
- 暂存区：空
- 本轮未 push，仓库未配置可用于本轮发布的远端流程
- 用户原有工作继续保留且未暂存：
  `ImageAll.xcodeproj/project.pbxproj`、`ImageAll/Assets.xcassets/`、`design/`、`scripts/`、`user/`

## 2. 本轮已关闭的本地门

1. production standard 准入契约、严格离线 evidence verifier 与候选资源预筛；Places365 仍按证据保持
   `research`，没有下载或伪装成生产批准包；
2. 固定 DINOv2 Core ML 的实际 ANE 区间、预编译安装、RSS/热量/1,000 次稳定性与资源 trace；
3. Backend cache-only personal rebuild，以及 App 运行期 30 秒防抖、持久、快照复核的自动个人重训；
4. 独立 loopback 服务的“进程启动 → ready → 合成 HTTP 请求 → 确定性关闭”验收器，并以固定
   DINOv2 Core ML 实际完成 384 维有限 embedding；
5. App 自动重训切片：Backend `173 passed, 2 skipped`；App 业务测试 937 项直接通过，3 项只依赖签名
   宿主资源/entitlement 的测试在宿主态通过；Debug build、PrivacyInfo 静态解析与 strict codesign 通过；
6. 服务启动切片：Backend `182 passed, 2 skipped`，compileall、sdist、wheel、console entrypoint、
   standard fixture 与真实 DINOv2 Core ML 两条进程探针通过。

实现与产品/架构文档保持分离提交；当前相关收口提交为：

- `8946846` — Backend cache-only personal rebuild；
- `42b6423` / `7f406e7` — App 自动重训实现 / 文档；
- `7e0874b` / `3b6a276` — 服务启动验收器 / 文档与去标识证据。

## 3. 仍开放但不能继续静默实施的门

### A. production standard package：外部证据阻塞

Places365 ResNet18 的官方预训练权重仍没有可复核的版本化许可文本与官方字节 SHA-256，当前公开用途
说明也不足以证明产品分发许可。缺少这三项前，不得下载权重、运行生产 benchmark、生成批准 package
或替换现有 fixture。解除条件是
[`STANDARD-MODEL-ADMISSION-SPEC.md`](./STANDARD-MODEL-ADMISSION-SPEC.md) 要求的官方权重、许可义务和
公开数据 manifest 全部 verified；之后才按 suggested-only 质量门、Core ML parity/resource/ANE 与 App
capability 门继续。

### B. 真实数据门：需要项目所有者对具体动作的新授权

- 阶段 1：外置盘小型真实文件夹的添加、重启恢复、拔盘、重连与增量重扫；
- 阶段 2：System Photo Library 实际切换和显式重绑定人工 smoke；
- 阶段 4：真实摄影格式/内容分布与端到端大容量图片 I/O。

这些门不能由合成 fixture 或旧授权替代。任何下一次读取都必须先明确具体来源、动作、只读证明和停止
位置。受保护图库所在卷挂载时还禁止启动 production App 测试宿主：2026-07-20 已观测到即使只选择
无关测试，宿主启动仍会尝试初始化真实 Photos store；详见
[`LOCAL-TEST-DATA-SAFETY.md`](./LOCAL-TEST-DATA-SAFETY.md)。

### C. App 自动托管模型服务：需要先决定发布架构

当前仓库只有 Python/uv 独立服务，没有随 App 签名分发的 helper/XPC target。推荐继续保持“App 可在
无模型模块时完整运行 + 独立 loopback 服务显式安装/启动”的 MVP 边界，禁止用 `Process` 启动工作区
`.venv`。如果项目所有者要求普通用户从 App 启停模型能力，应先选择 Developer ID 或 Mac App Store
分发方式，再冻结 signed helper/XPC、安装升级、代码签名、模型路径、端口占用、崩溃恢复、App 退出和
卸载契约；该选择会修改 Xcode 工程，并与当前用户未提交的工程/App Icon 改动重叠，不能静默开工。

## 4. 推荐恢复顺序

1. 若先取得 production standard 官方证据，优先恢复 standard admission benchmark；这是唯一能把
   当前公开 fixture 升级为真实公共模型的路径。
2. 若先取得具体真实数据只读授权，按“阶段 1 小型文件夹 → 阶段 2 显式重绑定 → 阶段 4 大容量 I/O”
   顺序执行，并避免 production App 测试宿主自动接触 Photos。
3. 若先确定 App 分发方式且明确要求自动托管，再单独设计 signed helper；在此之前不修改 Xcode 工程。

在上述任一解除条件出现前，当前批准计划内没有还能通过继续本地实现而诚实关闭的门。评测 cohort、
开放词表、区域证据、FastViT student、Ollama adapter、XMP sidecar 和批量 iCloud 分析继续属于明确延期
能力，不把它们冒充当前 MVP 缺陷。
