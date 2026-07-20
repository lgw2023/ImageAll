# ImageAll 生产 standard 模型准入规格

> 状态：Evidence verifier implemented；Places365 ResNet18 当前仅为 `research` 候选<br>
> 日期：2026-07-20<br>
> 适用范围：阶段 5 的首个生产 standard scene pack

## 1. 目标与停止位置

本规格把“公开模型可下载”与“ImageAll 可以安装并发布该模型”分成两个明确状态。候选只有在来源、
许可证、权重、预处理、评测集、校准、Core ML 转换和目标 Mac 资源证据全部通过后，才能成为
`approvedSuggestedOnly` 的生产 standard pack。任一证据缺失都必须 fail closed。

本规格不授权：

- 自动下载模型、数据集或许可证不明确的图片；
- 读取 `user/`、`/Volumes/HDD2`、任何 `.photoslibrary` 或真实用户照片；
- 把候选接入 App、替换现有 `imageall-public-fixture@pack-v1`，或创建模型安装 UI；
- 启用 `autoAssigned`。首个生产包即使获批也只能进入 Review Queue。

## 2. 候选档案

首个候选固定为 CSAILVision Places365 ResNet18，不接受仅凭文件名、默认分支或第三方模型卡替换：

| 字段 | 冻结值 |
|---|---|
| 上游仓库 | `https://github.com/CSAILVision/places365` |
| 上游 commit | `8a953ed56438726dc98bdef3796d042e7f1f171e` |
| 官方权重 URL | `http://places2.csail.mit.edu/models_places365/resnet18_places365.pth.tar` |
| 官方响应元数据 | `Content-Length=45506139`；`Last-Modified=2017-07-10T18:17:11Z`；`ETag="2b65e5b-553fa97795360"` |
| 官方权重 SHA-256 | `2f4759217d470da2b803f8f66cd4488a066406b555a5fb95ee9a4663f9f05588`；2026-07-20 已以 MIT 官方 URL 实际返回字节复核，文件大小 `45,506,139` bytes |
| 架构 | torchvision ResNet18，365 logits |
| 预处理 | RGB；resize `256×256`；center crop `224×224`；`ToTensor`；mean `[0.485,0.456,0.406]`；std `[0.229,0.224,0.225]` |
| provider identity（预留） | `places365-resnet18`；在许可证、数据、评测与转换全部 approved 前不得写入可安装 manifest |
| model identity（预留） | `csailvision/places365-resnet18`；revision 必须包含上述 verified 权重 SHA-256 |
| preprocessing revision（预留） | `places365-resnet18-center-crop-v1` |

官方字节证据已由项目所有者提供并迁入只读目录
`ModelBackend/research/inputs/places365/20260720T020727Z/`。该目录中的 `curl-metadata.txt`、
`response-headers.txt`、伴随 SHA 文件与实际 checkpoint 共同证明 URL、HTTP 200、Content-Type、
Content-Length、Last-Modified、ETag、文件大小和 SHA-256；不得重新下载或用第三方镜像替换该输入。
原始 checkpoint 只属于研究输入，永不进入 Xcode resource 或 App bundle。

上游小文件也固定到同一 commit，并在获取或生成 mapping 时复核：

| 文件 | SHA-256 |
|---|---|
| `README.md` | `1de70ec4bb303cc7e8ab569bbdb7ab835112ee5c16cdbb73328acbb33895b521` |
| `LICENSE` | `d4e65e5f2171ee6cca57b0f15ef1da5f11e91a170b6f4511342574b8e2d046c2` |
| `categories_places365.txt` | `2affba635eb657e7ca95f4e6cc69bd9fac29ef4c32aeb83cafdfcd06ec6a1ea6` |
| `IO_places365.txt` | `49f8c7fbeeb70deb055c040a1807a95b234bbac92902e1b6edfffbdd8411e1f1` |
| `run_placesCNN_basic.py` | `bd9a53ec5e833017dca380fb71aed7fa3485f3ca8733eb16055048a7f72bdd8b` |

### 2.1 许可证判定

- 仓库代码的 `LICENSE` 是 MIT；
- 固定 commit 的 README 对预训练权重只声明 Creative Commons Attribution（`CC BY`），没有给出
  版本号或完整许可证文本；因此暂记为
  `LicenseRef-Places365-Pretrained-CC-BY-Unversioned`，不得伪写成 `CC-BY-4.0`；
- 官方 Places 项目主页又把数据库和已训练 CNN 描述为供 academic research / education 使用；数据下载
  条款进一步限定为 non-commercial research / education。它们不能与未标版本的 `CC BY` 静默合并成
  产品分发许可，当前按更保守边界处理；
- 任何内部 benchmark 都必须保留上游项目页、论文和作者归属；
- 在权重许可证版本和分发义务被完整记录前，候选不得进入可再分发 App/package。第三方镜像的
  `MIT` 元数据不能扩大上游权重授权。

### 2.2 不可信 artifact 边界

上游 `.pth.tar` 是旧版 PyTorch checkpoint。研究环境只允许在隔离临时目录中以当前 PyTorch
`weights_only=True` 加载；若安全加载失败，候选直接拒绝，不得回退任意 pickle 反序列化。
产品包只能包含重新导出的、manifest 覆盖且经过 SHA-256 校验的 Core ML artifact，不包含原始
`.pth.tar`。

### 2.3 第二候选只读资源预筛

固定 revision `94dffa8cb1179de3e03f091dbc3917e5d5a9ae84` 的
`google/siglip2-base-patch32-256` 官方 Hugging Face 仓库标记 Apache-2.0，但仓库约 1.55 GB，主
`model.safetensors` 约 1.51 GB。它远超首包 80 MiB artifact 门，因此不下载、不走直接 production
pack 路径，继续只作为 teacher/开放词表研究候选。未来若裁剪视觉塔、量化或蒸馏得到较小产物，必须
作为新的 model/conversion revision 重新走全部准入；源文件大小不能冒充最终 Core ML 实测值。

## 3. 准入状态机

候选只有以下状态：

1. `research`：允许保存来源元数据和规格；禁止下载、转换、安装或推理；
2. `evaluationReady`：官方字节 SHA-256、许可证文本/义务和评测集 manifest 已验证；允许在独立临时
   目录运行离线 benchmark，不允许 App 安装；
3. `approvedSuggestedOnly`：第 4 节全部通过；允许生成新的、不可变 standard pack，但策略只能是
   `suggested`；
4. `rejected`：安全加载、来源、许可证、质量、转换或资源任一硬门失败。

状态只允许由完整证据重新计算，不接受人工把缺字段报告标成 approved。新的上游 commit、权重 SHA、
类别顺序、预处理、ontology、mapping 或 policy 都是新候选，不能沿用旧证据。

当前判定为 `research`。官方权重字节 SHA-256 已 verified；开放证据是：权重许可证版本与分发义务、
评测集许可证/manifest、离线指标、Core ML parity、目标 Mac 资源以及最终 pack 复核。

## 4. 评测与批准门

### 4.1 数据安全和可复现性

- 准确率/校准集必须是公开、允许本用途且有固定 revision 的场景图片集；manifest 至少记录 dataset
  ID/revision、split、每个文件 SHA-256、许可文件 SHA-256、ground-truth label 和样本唯一 ID；
- 数据不提交进本仓库，不记录本机绝对路径；报告只记录 manifest SHA、聚合指标和错误码；
- calibration 与 holdout 按 manifest 中稳定 ID 预先分离，禁止看过 holdout 后改 mapping 或阈值；
- 程序生成 RGB 只用于 loader、预处理、确定性和 Core ML parity，不得计入准确率或覆盖率；
- 禁止使用受保护照片、用户目录库纠错或网络抓取后许可不明的图片。

### 4.2 质量门

provider 先在冻结的 365 类 holdout 上报告 top-1/top-5 accuracy 和混淆矩阵；这些指标只用于发现
权重、类别顺序和预处理错误，不直接成为 ImageAll 标签质量。

ImageAll mapping 必须另做 concept-level 评测：

- mapping 只引用固定 `categories_places365.txt` 的 label，且只映射到已发布 ontology concept；
- calibration split 只用于选择每个 concept 的 `suggest_at`；首包 `auto_assign_at = null`；
- holdout micro precision `>= 0.80`，每个启用 concept precision `>= 0.65`；
- holdout micro coverage `>= 0.20`，并报告每个 concept 的 support、precision、recall 和 coverage；
- 任一 concept support `< 25` 时不得进入首包；不得用 macro/micro 聚合掩盖单 concept 失败；
- score 不能显示为概率；若进行温度缩放，必须同时报告未校准/校准 ECE 和拟合 split，不能跨
  provider 或 revision 复用温度。

未达到上述门可以保留研究报告，但结果必须是 `rejected`，不得降低门槛后复用同一 holdout。

### 4.3 Core ML 与资源门

- 固定输入为 `1×3×224×224 float32`，输出为 `1×365 float32` logits；
- PyTorch 与 Core ML 在整个公开 holdout 及至少 8 张程序生成边界图上，每张 cosine `>= 0.999`、
  relative L2 `<= 0.02`，top-1 必须完全一致；
- `.mlpackage` 及编译产物都要以内容 SHA-256 进入 manifest，转换过程不得联网补取权重；
- 当前目标 Apple Silicon Mac 上：模型 artifact `<= 80 MiB`、冷加载 `<= 2 s`、单图预热后
  median `<= 50 ms`、p95 `<= 100 ms`、峰值 RSS 增量 `<= 350 MiB`；
- “冷加载”从 Python/Core ML runtime 依赖初始化完成后开始，覆盖 manifest/checksum 校验与
  `MLModel`/`CompiledMLModel` 装载；依赖初始化时长必须另列，不能并入后再静默忽略。RSS 基线同样在
  依赖初始化和程序生成输入准备后、模型装载前采集。端到端“新进程启动 → 服务 ready”是独立产品门，
  不得用本模型加载指标冒充；
- 分别记录 `CPU_ONLY` 和 `ALL`。`ALL` 通过不等于实际 ANE 调度；在独立 ANE 门关闭前不得宣称 ANE；
- 1000 次程序生成输入顺序推理必须零崩溃、零非有限输出，且不创建来源侧文件。

### 4.4 App 与 package 门

- 新 package 的 manifest、ontology、mapping、policy、license 和 Core ML artifact 通过现有严格 loader；
- capability 返回的 manifest/weights/ontology/provider/mapping/policy 完整身份与 App 内唯一批准 package
  精确一致；
- 单图和全库仍在任何安装、读图、入队和旧结果清理前完成 capability 门；POST/任务发布保留第二身份门；
- 全部结果固定 `pendingReview`/`suggested`，人工接受或拒绝继续覆盖机器结果；
- optional 模块缺失或候选被拒绝时，浏览、人工标签、Feature Print、personal 路径和现有 fixture 回归
  不受影响；
- 自动化只使用临时目录、公开 fixture 和程序生成图片，Apple Development 串行全量测试、Debug build
  与 strict codesign 必须通过。

## 5. 机器可验收证据契约

`1699138` 已实现离线 verifier，不下载或运行模型。输入报告必须显式提供：候选 identity、全部
来源/许可证/权重 SHA、dataset manifest SHA、样本计数、provider 指标、逐 concept 指标、Core ML
parity、资源指标和 pack validation 结果。verifier 必须：

- 严格拒绝未知字段、缺字段、非法或 uppercase SHA-256、非有限数值和重复 concept；
- 根据第 3～4 节计算状态，不能相信输入中的 `approved` 布尔值；
- 任一已经 measured 的硬门失败应立即得到 `rejected`；其他门尚未 measured 不能把已知失败降级为
  `evaluationReady`；
- 输出不含路径的稳定 JSON decision 和逐门 reason code；
- `approvedSuggestedOnly` 返回退出码 0；证据完整但未过门返回 2；畸形报告返回 3；
- 当前 Places365 候选 fixture 虽已复核官方权重 SHA，但因许可证版本/产品分发义务和公开数据 manifest
  未 verified，必须稳定得到 `research`，且不生成 standard pack。
- `ModelBackend/research/manifests/places365-public-validation-20260720.json` 是显式 blocker manifest：
  它固定记录 dataset identity、版本、许可证和 item 列表均未获批准，`items` 必须为空。该文件只证明
  “公开验证门仍缺失”，不得冒充 dataset manifest、评测结果或 `evaluationReady` 证据。

CLI 为 `imageall-verify-standard-admission --report <json>`；批准返回 0，研究/待评测/拒绝返回 2，畸形
报告返回 3。仓库内 `places365-resnet18-research-v1.json` 固定当前候选证据并稳定返回 `research`。

验收为 verifier 定向 `21 passed`、Backend 全量 `141 passed, 2 skipped`；compileall、sdist 和 wheel
build 通过。测试和 fixture 不含图片、模型权重或本机路径，未下载模型/数据集，未读取受保护数据。

后续独立切片只有在许可证和数据均由显式、已审核输入提供时才可运行 benchmark runner。当前权重
字节已由项目所有者明确提供，但官方许可表述仍相互不充分，不满足 `evaluationReady`；因此不得加载
checkpoint、转换或产品接入。若未来许可证门关闭，runner 也只能在隔离临时目录以
`torch.load(..., weights_only=True)` 使用该只读输入，禁止任意 pickle 回退。

## 6. 主要来源

- CSAILVision Places365 固定仓库：
  `https://github.com/CSAILVision/places365/tree/8a953ed56438726dc98bdef3796d042e7f1f171e`
- 固定 README（模型来源、预处理示例、权重许可声明）：
  `https://raw.githubusercontent.com/CSAILVision/places365/8a953ed56438726dc98bdef3796d042e7f1f171e/README.md`
- 固定代码许可证：
  `https://raw.githubusercontent.com/CSAILVision/places365/8a953ed56438726dc98bdef3796d042e7f1f171e/LICENSE`
- Places 项目主页和数据条款：`https://places2.csail.mit.edu/`、
  `https://places2.csail.mit.edu/download-private.html`
- SigLIP2 固定 revision：
  `https://huggingface.co/google/siglip2-base-patch32-256/tree/94dffa8cb1179de3e03f091dbc3917e5d5a9ae84`
- Places365 论文：`https://arxiv.org/abs/1610.02055`
