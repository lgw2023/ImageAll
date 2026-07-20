# ImageAll 后续开发门审计（2026-07-20）

## 1. 实时基线

- 分支：`main`
- 审计开工 HEAD：`3b6a276fada7a059d2ee48de2c693f68cecf5dad`
- App 内 Core ML 初版基线：`b87a82e82392e82f54938d681ae130a9c0c82a64`（外部状态变化已同步到
  `origin/main`；该提交同时包含此前 staged 的 App Icon 工作，未改写历史）
- 本地边界修复：`2aaa7d19f185f8eb18bdff3ccb60a446910fef88`；相关四个 Core ML 收口提交已于
  2026-07-20 以 ahead 4 / behind 0 的无分叉状态推送，推送后
  `HEAD == origin/main == 20d08f805d5561b6dbdde5b06be5e6feb36cbb34`
- App 内模型能力管理切片开工基线：`main@20d08f805d5561b6dbdde5b06be5e6feb36cbb34`；实现提交：
  `573add4da1565ea19c82bd963d613affe85fafca`
- App 内版本化 embedding cache 切片开工基线：
  `main@d9f53fc0694553ace5be341dfc6cf2e506b341f8`；实现提交：
  `393e0dcdf8a4656bb91c1f6cc3a54ef219b89129`
- embedding cache 资源与生命周期切片开工基线：
  `main@6abc00737e70ce773e162096b032969cc8500226`；实现提交：
  `f2cac3373bd03db04c41f5b07981db26ec4d2cc5`
- App 内个人线性 head tracer 开工基线：
  `main@b12cf6eaec17e79c996272e67afba7ea21b4180a`；实现提交：
  `cbf7770a4cef62ad3503ab0159738048535d8581`
- App 内个人 head managed artifact 切片开工基线：
  `main@bb5485d1364bbed33730df258ff1fab0d67eef11`；实现提交：
  `88b0b2afc276c7ddc2b22eb92e3df68b080ef070`
- App 内个人模型生产只读接线切片开工基线：
  `main@3cc914cd328de4633db9dbeb115b7197be7b36e9`；实现提交：
  `173a11768d79ee621cf94ada3f505c566b0a3aa3`

### 1.1 本机凭据日志风险决定

项目所有者确认：包含 API 环境变量的日志只保存在不对他人开放的本机，没有进入 Git/GitHub 历史，
也没有发送或同步到第三方或外部服务；项目所有者接受当前风险并决定暂不轮换。因此“先轮换 API Key”
不再是本项目继续开发的前置门。该决定不是对凭据永久安全性的保证；后续构建、测试、Git 和网络命令
仍使用不含 API 环境变量的最小环境，提交前继续执行凭据字面量扫描，任何新外发证据都不得包含凭据值。

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
   SHA-256、manifest 与 DINOv2-small identity；conversion provenance 另锁定 source `.mlpackage` SHA
   `cd6f6e9fd2219e04b6a831f70af84a2ef53be456ec01b530bb4d1c6b93a7a416`、`torch.jit.trace`、
   torch 2.7.0 与 coremltools 9.0。程序生成图片返回 384 维有限 embedding；未启用、缺失、
   manifest 损坏和模型字节损坏均 fail closed。正式 App target 已移除 loopback client，普通 App 包中
   Python/`.pth.tar`/helper/XPC/loopback 字面量均为 0；Core ML、开发侧 loopback 合同、组合根、浏览与
   单图人工标签定向回归 `30/30`。完整无宿主 XCTest 为 947 项，其中 944 项通过；其余 3 项仅因
   `Bundle.main` 不是 App 宿主而失败，普通 App 静态审计已分别确认 Privacy manifest 和签名
   entitlements。受保护图库挂载期间没有启动 App 宿主。
8. App 内模型能力管理：全局 UserDefaults 只持久化启用意图，默认关闭时模型工厂调用为 0；非主线程
   actor 串行执行 bundle artifact 校验/初始化，并提供 `disabled → validating → ready(identity) |
   unavailable(reason)` 状态。失败保留启用意图，关闭释放服务，重复/并发启用共享单次初始化，新 App
   生命周期和 artifact 更新都会重新校验。原生 Settings 只显示固定本机 Core ML 运行方式、已校验
   model identity 和去路径/异常栈的失败文案；没有接入 LibraryWorkspace、图库扫描、SQLite 或个人模型。
   TDD 定向为能力管理 `11/11`、既有 Core ML 服务 `6/6`、组合根 `5/5`。完整直接 xctest 执行 958 项，
   仅 3 个必须依赖 App 宿主身份的测试产生 6 个断言失败（2 个 `Bundle.main` 资源测试、1 个当前进程
   entitlement 测试）；其余通过。受保护图库挂载期间未启动 App 宿主。独立 Release build 成功，
   manifest/license 源与包内 SHA 一致，Python/原始权重/XPC/helper/loopback 禁入计数为 0；临时包按项目
   entitlements ad-hoc 签名后通过 strict codesign 验证。
9. App 内版本化 DINO embedding cache：App artifact manifest 升为 revision 2，固定
   `dinov2-cls-token`、`raw-float32-v1` 与 `float32` 输出语义；缓存地址绑定 catalog/asset/content
   revision、encoder/preprocessing/postprocessing、元素语义及完整 artifact provenance。缓存只写 App
   Caches 下的有限 little-endian Float32 向量、完整身份与向量 SHA-256，不保存图片、路径或 bookmark；
   exact hit 跨实例复用，content revision 变化 miss，SHA 篡改或校验和正确的 NaN 均重建，缓存持久化
   失败退化为实时 embedding，模型关闭时不创建缓存。同实例 8 个并发同 key 请求收敛为 1 次生成和
   7 次命中。TDD 定向为 cache `7/7`、Core ML `6/6`、能力管理 `11/11`、Composition Root `6/6`。
   完整非宿主 xctest 执行 967 项，仍仅上述 3 个宿主身份测试产生 6 个环境断言失败；Release build、
   strict codesign、manifest/license 源包 SHA 一致性与 Python/权重/XPC/helper/loopback 禁入计数均通过。
   受保护图库挂载期间未启动 App 宿主，也未读取 `/Volumes/HDD2`。
10. embedding cache 资源与生命周期：cache record schema 升为 2；不同 cache 实例先经进程锁收敛，
    再以 `ModelEmbeddings/v1/lifecycle.lock` 的 POSIX 文件锁覆盖 lookup、Core ML inference、原子发布与
    回收。8 个不同实例对同 key 并发得到 1 次 generation 和 7 次 hit。对象预算默认固定为 256 MiB，
    只统计并淘汰 `ModelEmbeddings/v1/objects` 下的常规 `.embedding` 文件；测试证明单条预算下旧对象
    被回收、上级无关 sentinel 保持不变、最新对象继续命中。首次成功维护会清理无法解码、旧 record
    schema 或完整模型身份不匹配的自有对象；锁、缓存根、维护、写入或回收失败仍退化为实时有限
    embedding，模型错误不被吞掉。TDD 实际观察到跨实例 `8 generated / 0 hit`、缺少容量接口、旧 schema
    孤儿残留和旧 identity 孤儿残留四个 RED，随后逐项 GREEN。定向 cache `11/11`，连同 Core ML、能力
    管理和 Composition Root 为 `34/34`；完整非宿主 xctest 执行 971 项，仍只有既有 3 个宿主身份测试的
    6 个环境断言失败。Release build、strict codesign、manifest/license 源包 SHA 一致及
    Python/原始权重/helper/XPC/loopback 禁入计数均通过。未启动 App 宿主、未读取 `/Volumes/HDD2`、
    `.photoslibrary` 或真实照片。
11. App 内个人线性 head tracer：Swift 从只读 `PersonalModelRebuildSnapshot` 消费内存中的有限合成
    embedding 与人工正负决定，以每标签 `2 + 2` 为硬门，确定性训练 centroid-difference Float32 线性
    head；推理使用 Accelerate `vDSP`，只返回 artifact 已绑定标签中的有限正分建议。排序、catalog
    scope、人工决定快照、标签词表、完整 Core ML encoder identity、稳定标签顺序和参数 SHA-256 均写入
    可重载 artifact；重复决定、缺少样本、参数篡改或推理 encoder 身份不匹配全部 fail closed。TDD
    逐项观察到缺训练/加载接口、缺 `2 + 2`、参数篡改未拒绝、只核对部分 encoder identity 和重复决定
    未拒绝五个 RED，随后逐项 GREEN；head `5/5`，连同 cache、Core ML service、能力管理和 Composition
    Root 为 `39/39`。完整非宿主 xctest 执行 976 项，仍只有既有 3 个宿主身份测试产生 6 个环境断言
    失败；Release build、strict codesign、manifest/license 源包 SHA 一致，以及 Python/原始权重、嵌入式
    helper/XPC 和 loopback 运行引用禁入均通过。该 tracer 本身没有持久化 active artifact，也没有接入
    LibraryWorkspace、SQLite、图库扫描、Review Queue 或真实照片；未启动 App 宿主，未读取
    `/Volumes/HDD2` 或 `.photoslibrary`。
12. App 内个人 head managed artifact：actor 只在 App Application Support 下维护内容寻址的
    `.personal-head` 对象和单一 `active.json`。候选先经现有模型解码、artifact SHA、完整 catalog/Core ML
    encoder identity、落盘字节和 no-follow 重载复核，再原子切换 active；重启只从该指针恢复，不枚举
    objects 猜测回退。缺失、损坏或旧 identity 分别稳定报告独立 unavailable；写入失败、候选对象链接、
    父目录链接或 identity mismatch 均保留旧内存 capability，损坏 active 禁止推理。TDD 观察到缺 managed
    API、缺 capability getter、缺 unavailable 推理门、候选链接被替换和父目录链接被跟随五类 RED，随后
    GREEN；store `6/6`，连同 head、cache、Core ML service、能力管理和 Composition Root 为 `45/45`。
    完整非宿主 xctest 执行 982 项，仍只有既有 3 个宿主身份测试产生 6 个环境断言失败。Release build、
    strict codesign、manifest/license 源包 SHA 一致，以及 Python/原始权重、嵌入式 helper/XPC 和 loopback
    运行引用禁入均通过。没有接入 LibraryWorkspace、SQLite、图库扫描、Review Queue 或真实照片；未启动
    App 宿主，未读取 `/Volumes/HDD2` 或 `.photoslibrary`。
13. App 内个人模型只读重建编排 tracer：显式 `rebuild()` 只从两个 `Sendable` 只读端口取得人工事实与
    已缓存 embedding，规范化 catalog/决定/标签 revision，调用既有 Swift/Accelerate trainer，并只通过
    managed artifact store 发布。actor 同时只允许一个 rebuild，支持显式取消；训练后、发布前重新读取
    人工事实并比较 revision，过期、取消、cache error/miss、encoder 不匹配或每标签不足 `2 + 2` 均在
    发布前 fail closed，旧 active 保持可用。TDD 逐项观察到缺 rebuild 接口、缺二次快照复核、缺取消、
    缺单运行错误、cache 错误未收敛和训练错误未收敛六类 RED，随后 GREEN；coordinator `6/6`，连同
    managed store、head、cache、Core ML service、能力管理和 Composition Root 为 `51/51`。完整非宿主
    xctest 执行 988 项，仍只有既有 3 个宿主身份测试产生 6 个环境断言失败。Release build、strict
    codesign、manifest/license 源包 SHA 一致，以及 Python/原始权重、嵌入式 helper/XPC 和 loopback
    运行引用禁入均通过。该 tracer 只使用合成事实/cache adapter；尚未把生产 GRDB/cache adapter、
    Composition Root 或 UI 动作接入，也未启动 App 宿主或读取 `/Volumes/HDD2`、`.photoslibrary` 或真实照片。
14. App 内个人模型生产只读接线：`AppPersonalTrainingSnapshotPortSource` 只经既有 review 边界取得人工
    事实，`AppPersonalTrainingEmbeddingCacheSource` 只按 catalog/asset/content revision 与当前完整 Core ML
    identity 查询既有 App cache；miss、损坏和 identity 不匹配不接受图片输入，也不触发 Core ML 或创建
    cache。App 启动时让 Settings 与 workspace 共享同一个 `AppModelActivationCoordinator` 和已校验
    `AppCoreMLEmbeddingService`，工具栏显式“重建个人模型”直接运行 Swift/Accelerate coordinator，不启动
    Python、HTTP、helper/XPC 或第二份模型。未启用时不创建 cache/head 路径；cache miss 显示独立安全提示，
    浏览和人工标签保持可用。TDD 定向为 cache `13/13`、coordinator `9/9`、activation `12/12`、
    Composition Root `7/7`、managed store `6/6`、head `5/5` 与 workspace `106/106`。完整非宿主 xctest
    执行 997 项，仍只有既有 3 个 App 宿主身份测试产生 6 个环境断言失败。Universal Release build、
    strict codesign、entitlements、模型/许可证/Privacy manifest 源包一致性，以及 Python/原始权重、
    embedded helper/XPC 和 loopback 字面量禁入均通过。未启动 App 宿主，未读取 `/Volumes/HDD2`、
    `.photoslibrary` 或真实照片，也未接图库扫描、Review Queue 或个人模型建议展示。
15. 当前选中单资产显式 App 内 DINO cache 填充：workspace 工具栏动作只在恰好选中一个资产时开放，
    先复用共享激活 actor 确认当前固定 Core ML service ready，再通过既有受控 preview 边界读取这一张
    资产，并按精确 catalog/asset/content revision 与完整模型 identity 写入一个版本化 embedding。
    未启用或模型不可用时在 preview 读取前停止；iCloud-only 不自动下载；缓存发布后还会 cache-only
    回读并复核 identity 与向量 SHA，持久化失败显式 fail closed，浏览和人工标签状态保持不变。程序生成
    PNG 的 Core ML 测试得到 384 维有限且身份匹配的 embedding，并只形成一个 cache 对象；定向非宿主
    xctest 为 `144/144`。完整非宿主 xctest 执行 1003 项，仍只有既有 3 个 App 宿主身份测试产生 6 个
    环境断言失败。Universal Release build、strict codesign、完整模型资源树/许可证/Privacy manifest
    源包一致性，以及 Python/原始权重、embedded helper/XPC 和 loopback 字面量禁入均通过。未启动 App
    宿主，未读取 `/Volumes/HDD2`、`.photoslibrary` 或真实照片，也未接图库扫描、批量预热、后台任务、
    Review Queue 或个人建议展示。
16. 真实人工验证的标签创建前置门：首次 production App 启动在人工样本开始前暴露“数据库标签事务与
    当前选择呈现可能失同步”。`197a056` 以四条 RED→GREEN 纵向回归修复：真正写入失败继续返回
    `tagMutationFailed` 且零 UI/数据库半事实；事务已提交但 inspector 后置读取失败时，当前选择保留
    已确认标签并返回独立 `tagSelectionRefreshFailed`，明确不谎报未保存；重新选择同一照片会重新读取
    持久层并清除临时告警。workspace model 与真实 GRDB 标签事务合计 `147/147`，完整非宿主 xctest 为
    1007 项，仍只有既有 3 个 App 宿主身份测试产生 6 个环境断言失败。Universal Release、strict
    codesign、Privacy manifest、双架构和 production 包禁止项通过；production Swift 仍无 Photos mutation
    API。此门只修复人工标签前置能力，没有读取真实照片或扩大 PhotoKit 授权。

实现与产品/架构文档保持分离提交；当前相关收口提交为：

- `8946846` — Backend cache-only personal rebuild；
- `42b6423` / `7f406e7` — App 自动重训实现 / 文档；
- `7e0874b` / `3b6a276` — 服务启动验收器 / 文档与去标识证据；
- `573add4` — App 内模型启用偏好、激活 actor、原生 Settings 与 TDD 验收；
- `393e0dc` — App 内完整语义身份、版本化 embedding cache、损坏恢复与生产组合根；
- `f2cac33` — 跨实例/进程生命周期锁、256 MiB 对象预算和旧 schema/identity 清理；
- `cbf7770` — App 内确定性 Swift/Accelerate 个人线性 head 合成 tracer；
- `88b0b2a` — App 内个人 head 候选复核、原子 active、重启恢复与独立 capability。
- `6f8e819` — App 内只读事实/cache 重建、取消、快照复核和 managed artifact 发布编排。
- `173a117` — 生产人工事实/cache-only adapter、共享 App Core ML 激活实例和显式原生重建动作。
- `916422c` — 当前选中单资产显式 App 内 DINO cache 填充与安全降级。
- `197a056` — 标签创建提交态、选择刷新失败分类与重新选择收敛。

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
用户运行路径。固定 artifact tracer、App 内模型启用选择/持久化/状态呈现、显式单图版本化 embedding
cache 及其跨实例原子发布、有界容量/回收、identity 升级清理、只消费合成快照的 App 内
Swift/Accelerate 个人线性 head，以及个人 head 的 App 容器内 managed artifact 生命周期与独立能力
状态均已关闭。显式调用下的只读事实/cache 端口、单运行调度、取消、快照二次复核和 managed artifact
发布编排，以及生产 GRDB review 事实 adapter、App cache-only adapter、共享激活实例、工具栏原生重建
和当前选中单资产显式 DINO cache 填充也已关闭。下一门可用一个个人标签的 `2 accepted + 2 rejected`
真实人工小批验证这条全原生路径，但必须先取得针对 HDD2/PhotoKit 来源、production App 启动、只读动作、
App 容器输出和停止位置的新授权；不得自动遍历图库、批量预热、触发 iCloud 下载或把 cache miss 隐式
变成后台照片读取，模型失败仍须与浏览、人工标签和既有 Feature Print 路径隔离。

## 4. 推荐恢复顺序

1. 当前选中单资产显式 App 内 DINO cache 填充已关闭。下一纵切片先冻结并执行一个个人标签的
   `2 accepted + 2 rejected` 真实人工小批 runbook：用户逐张显式选择并准备特征，再显式重建个人模型，
   只验证当前完整 encoder identity 下的 4 条 cache、原生 head 激活与失败隔离。任何 HDD2/PhotoKit 读取
   和受保护图库挂载时的 production App 启动，都须另列精确来源、只读动作、App 容器输出和停止位置并
   取得新授权；不得遍历 `.photoslibrary`、自动扫描、批量预热、触发 iCloud 下载、写源图库或接个人建议
   展示，也不得恢复 Python/HTTP/helper/XPC 用户依赖；
2. 并行补齐 Places365 权重许可版本/分发义务和真实公开验证数据 manifest；门关闭后才在隔离临时目录以
   `weights_only=True` 运行评测、转换、parity 与资源门；
3. 若先取得具体真实数据只读授权，按“阶段 1 小型文件夹 → 阶段 2 显式重绑定 → 阶段 4 大容量 I/O”
   顺序执行，并避免 production App 测试宿主自动接触 Photos。

Developer ID/Mac App Store 选择、helper/XPC 和 loopback 托管不再阻塞当前切片。评测 cohort、
开放词表、区域证据、FastViT student、Ollama adapter、XMP sidecar 和批量 iCloud 分析继续属于明确延期
能力，不把它们冒充当前 MVP 缺陷。
