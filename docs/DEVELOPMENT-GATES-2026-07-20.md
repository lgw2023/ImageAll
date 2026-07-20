# ImageAll 后续开发门审计（2026-07-20）

## 1. 实时基线

- 分支：`main`
- 审计开工 HEAD：`3b6a276fada7a059d2ee48de2c693f68cecf5dad`
- App 内 Core ML 初版基线：`b87a82e82392e82f54938d681ae130a9c0c82a64`（外部状态变化已同步到
  `origin/main`；该提交同时包含此前 staged 的 App Icon 工作，未改写历史）
- 本地边界修复：`2aaa7d19f185f8eb18bdff3ccb60a446910fef88`，未 push
- 文档开工前 `main` 比 `origin/main` ahead 1，工作树和暂存区为空

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
7. App 内固定 Core ML tracer：Swift 从实际 App bundle 校验 pinned Apache-2.0 来源、许可证/模型
   SHA-256、manifest 与 DINOv2-small identity，程序生成图片返回 384 维有限 embedding；未启用、缺失、
   manifest 损坏和模型字节损坏均 fail closed。正式 App target 已移除 loopback client，普通 App 包中
   Python/`.pth.tar`/helper/XPC/loopback 字面量均为 0；Core ML、开发侧 loopback 合同、组合根、浏览与
   单图人工标签定向回归 `30/30`。完整无宿主 XCTest 为 947 项，其中 944 项通过；其余 3 项仅因
   `Bundle.main` 不是 App 宿主而失败，普通 App 静态审计已分别确认 Privacy manifest 和签名
   entitlements。受保护图库挂载期间没有启动 App 宿主。

实现与产品/架构文档保持分离提交；当前相关收口提交为：

- `8946846` — Backend cache-only personal rebuild；
- `42b6423` / `7f406e7` — App 自动重训实现 / 文档；
- `7e0874b` / `3b6a276` — 服务启动验收器 / 文档与去标识证据。

## 3. 仍开放但不能继续静默实施的门

### A. production standard package：官方权重字节已关闭，许可和数据仍阻塞

项目所有者已提供从 MIT 官方 URL 实际下载的只读证据；响应元数据、`45,506,139` bytes 与
`2f4759217d470da2b803f8f66cd4488a066406b555a5fb95ee9a4663f9f05588` 已复核一致，因此“官方字节
SHA-256”门已关闭。权重仍只有未标版本的 `CC BY` 声明，官方项目页同时把 CNN/数据描述为
academic research / education 用途；当前不足以证明产品再分发许可。公开验证数据的许可与有效
dataset manifest 也尚未关闭；
`ModelBackend/research/manifests/places365-public-validation-20260720.json` 只记录缺失门，不是有效
数据集。在这两项完成前，不得生成批准 Places365 package、把 Places365 Core ML artifact 加入 App
target，或替换现有 fixture。解除条件是
[`STANDARD-MODEL-ADMISSION-SPEC.md`](./STANDARD-MODEL-ADMISSION-SPEC.md) 要求的官方权重、许可义务和
公开数据 manifest 全部 verified；之后才按 suggested-only 质量门、Core ML parity/resource/ANE 与 App
内 manifest/身份门继续。原始 checkpoint 只保存在 `ModelBackend/research/inputs/places365/`，不得进入
正式 App。

### B. 真实数据门：需要项目所有者对具体动作的新授权

- 阶段 1：外置盘小型真实文件夹的添加、重启恢复、拔盘、重连与增量重扫；
- 阶段 2：System Photo Library 实际切换和显式重绑定人工 smoke；
- 阶段 4：真实摄影格式/内容分布与端到端大容量图片 I/O。

这些门不能由合成 fixture 或旧授权替代。任何下一次读取都必须先明确具体来源、动作、只读证明和停止
位置。受保护图库所在卷挂载时还禁止启动 production App 测试宿主：2026-07-20 已观测到即使只选择
无关测试，宿主启动仍会尝试初始化真实 Photos store；详见
[`LOCAL-TEST-DATA-SAFETY.md`](./LOCAL-TEST-DATA-SAFETY.md)。

### C. App 模型部署方向：已决定为 App 内 Swift/Core ML

自动托管模型服务规划已经取消。正式 App 不分发或启动 Python/uv、loopback HTTP、helper/XPC，也不把
它们作为普通用户依赖。用户在 App 内选择启用模型后，App 只在自身容器中校验许可证、版本、SHA-256
与 manifest，随后由 Swift 直接加载 Core ML artifact，并让 Core ML 使用本机 CPU/GPU/Neural Engine。
模型未启用、缺失、损坏、身份不匹配或初始化失败时，模型能力安全降级，浏览、人工标签和既有
Feature Print 路径保持可用。Developer ID 与 Mac App Store 的选择不阻塞该接线。

`ModelBackend` 与既有 loopback 证据继续作为转换、离线评测和开发验证资产保留，但不再形成发布门或
用户运行路径。首个固定 artifact tracer 已关闭；下一实现门是“App 内模型启用选择 → 持久化设置 →
bundle artifact 初始化/状态呈现 → 失败不影响浏览和人工标签”。

## 4. 推荐恢复顺序

1. 下一纵切片接入 App 内模型启用选择，默认关闭；用户启用后只调用当前 Core ML bundle 工厂，显示
   ready/缺失/损坏状态，重启保持选择，任何失败不改变浏览和人工标签；
2. 并行补齐 Places365 权重许可版本/分发义务和真实公开验证数据 manifest；门关闭后才在隔离临时目录以
   `weights_only=True` 运行评测、转换、parity 与资源门；
3. 若先取得具体真实数据只读授权，按“阶段 1 小型文件夹 → 阶段 2 显式重绑定 → 阶段 4 大容量 I/O”
   顺序执行，并避免 production App 测试宿主自动接触 Photos。

Developer ID/Mac App Store 选择、helper/XPC 和 loopback 托管不再阻塞当前切片。评测 cohort、
开放词表、区域证据、FastViT student、Ollama adapter、XMP sidecar 和批量 iCloud 分析继续属于明确延期
能力，不把它们冒充当前 MVP 缺陷。
