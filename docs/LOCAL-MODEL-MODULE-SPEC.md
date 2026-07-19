# ImageAll 可选本地模型模块实施规格

> 状态：标准/个人 suggestion HTTP、双轨服务启动、个人训练 CLI、DINOv2 Core ML FP16 provider、完整 personal bundle/standard package capability 握手、Inspector personal 确认流、用户触发的原子重建、personal/standard 持久全库任务、显式服务状态、v009 标准概念持久化、v010 standard Review Queue、显式单图发布与 v011 标准祖先展开已实现；生产公共模型准入规格已冻结，实际模型评测/接入、ANE 取证与自动后台训练仍待后续门
> 日期：2026-07-19
> 开工基线：`main@14c3890b8c83c87a6f603c8900dfaabb3179ea6c`
> 范围：独立模型训练、部署与推理模块，以及可选的当前目录库确认/用户触发训练接线；不包含自动模型安装、自动后台训练或生产准确率承诺

## 1. 目标与停止位置

本模块为 ImageAll 提供可替换的本地视觉模型能力，但不是 App 的启动依赖。能力分为零用户样本即可
工作的标准标签公共模型，以及只从用户人工正负决定学习的个人标签模型。模块未安装、服务未启动、
权重缺失或单次推理失败时，App 仍须保留浏览、人工标签、历史标签预设和现有 Vision Feature Print
个性化建议闭环。

第一条 tracer slice 只完成：

```text
合成图片 bytes
→ loopback HTTP 推理契约
→ DINOv2-small embedding
→ 版本化 embedding 响应
```

同时提供一个可在 Apple Silicon 上运行的线性多标签 head 训练核心，以预计算 embedding
作为输入。第一切片停止于独立模块测试和合成图片真实 embedding smoke；不修改 Swift、
Xcode 工程、SQLite schema 或 App UI，不下载 SigLIP2、DINOv3、FastViT 或 Ollama VLM 权重。

标准轨道的第二、第三条 tracer 已在独立模块内完成：只读 package 校验、CC0 合成 RGB 线性
fixture、固定 mapping、ontology DAG、policy recommendation 和 standard `/v1/suggestions`。该 fixture
只证明版本化端到端契约，不是 Places365 或其他生产模型的准确率证据；CLI 已能装载该固定
`rgb-linear` package，Swift client 已能严格解码其 direct concept。App v009 已能原子安装合成
ontology/model identity 并以稳定 Tag 绑定区分同名个人标签；v010 已把 direct concept 作为可重建
`standard_prediction` 写入现有 Review Queue。公开 fixture 由用户在 Inspector 显式请求时才惰性安装、
推理和发布，启动与首次使用引导不依赖模型包；v011 按精确 ontology revision 展开 direct concept
的祖先并保留来源。用户还可从 Review Overview 显式启动 standard 全库持久任务；任务按稳定 Asset ID
分页、逐资产核对 pack 与内容 revision，只读取 local-only 预览，并把结果原子写入现有 Review Queue；
iCloud-only 资产跳过且不触发批量下载。标准服务现先通过 `GET /v1/capabilities` 公布已验证 package
的 manifest、ontology、provider/model、mapping、policy 与 weights 完整身份；App 只在该身份精确匹配
内置批准 fixture 后才安装 ontology、读取单图或入队全库任务。生产 provider 与真实照片验证仍未接入。

个人轨道的下一条 tracer 也已在独立模块内完成：`imageall-train-personal` 从版本化 DINO embedding
与稀疏人工决定快照训练线性多标签 head，未观察的 asset/tag pair 通过 observation mask 排除，并输出
带 catalog、bundle、encoder、标签词表和权重 hash 身份的只读 bundle。personal `/v1/suggestions`
现已加载该 bundle，只返回其中已有的 `tag_id` 且固定为 `suggested`；`GET /v1/capabilities` 先向 App
公布已验证的完整 bundle 身份与 `tag_ids`，请求和响应再做二次身份核对。Inspector 只允许当前
catalog 中仍为 active 的既有标签 UUID，用户点击接受或拒绝后才复用既有人工标签事务。App 现可从
每个合格标签最近的人工接受/拒绝决定构造 embedding 快照，由用户显式触发同步重建；该闭环不包含
生产照片准确率结论或自动后台训练。用户也可从 Review Overview 显式触发 personal 全库扫描；App
只读取 local-only 预览、每次推理后复核 capability，把既有 tag-only 结果写入 v008 可重建表并复用
当前 Review Queue，iCloud-only 资产不触发批量下载。服务 CLI 可通过 `--provider dinov2 --personal-bundle <path>`，或通过
`--provider coreml --coreml-bundle <path> --personal-bundle <path>`，同时装载实际 DINO provider
与个人 bundle，并在开始监听前拒绝缺少 provider 或 encoder identity 不一致的组合。

Core ML tracer 已把同一固定 DINOv2 revision 转换为 macOS 15+ FP16 ML Program，并输出带完整
encoder/preprocessing identity 和目录内容 SHA-256 的 artifact manifest。转换 CLI 只用程序生成 RGB
图片经固定 AutoImageProcessor 得到的 tensor 做数值与延迟基准；服务 CLI 现可用
`--provider coreml --coreml-bundle <path>` 装载 artifact，并复用 `/v1/embeddings` 与 personal
`/v1/suggestions`。artifact 未接入 App target，模块缺失时的原有降级边界不变。

## 2. 技术决策

### 2.1 训练与模型基准

- 训练/研究主线：PyTorch，设备优先级固定为 `mps → cpu`；Core ML 转换环境固定
  `torch == 2.7.0` 与 `coremltools 9.x`；
- 首个 encoder：`facebook/dinov2-small`，revision 固定为
  `ed25f3a31f01632728cabb09d1542f84ab7b0056`；
- 第二 benchmark：`google/siglip2-base-patch32-256`，revision 固定为
  `94dffa8cb1179de3e03f091dbc3917e5d5a9ae84`，只在后续独立切片下载；
- `timm/fastvit_t12.apple_dist_in1k` 作为未来端侧 student；
- DINOv3 ViT-S 仅为第四实验组；MobileCLIP2-S0 仅为内部端侧下界，不进入产品依赖。

首版只冻结 encoder 并训练可替换的线性多标签 head，不在个人照片上微调整个视觉
backbone。训练产物必须记录 encoder、模型 revision、预处理 revision、标签词表 revision、
权重 SHA-256 和训练设备。

模型职责按轨道固定：

| 候选 | 职责 | 准入状态 |
|---|---|---|
| Places365 ResNet18 | 标准场景标签、场景属性和 ontology mapping 的首个 tracer 候选 | `research`；固定上游 commit，但权重许可版本、官方字节 SHA、公开评测和 Core ML 门未关闭 |
| DINOv2-small | 个人标签冻结 embedding | 固定 revision 的 PyTorch/Core ML 独立服务与 FP16 artifact tracer 已实现 |
| SigLIP2 B/32 256 | 开放词表与标准概念候选评测 | 后续 benchmark |
| SegFormer-B0 ADE20K | 水域、天空、道路等标准标签的区域证据 | 研究候选，不单独决定标签 |
| RAM++ | 通用对象/属性候选 | 许可证、权重来源和转换门未关闭，不得进入产品 |
| FastViT-T12/T8 | 公共高频标签稳定后的端侧 student | 后续蒸馏候选，不承担动态个人词表 |

### 2.2 推理与部署

- Python 服务只允许绑定 `127.0.0.1`；
- App 或测试向服务传递单张解码后图片 bytes，不传任意本机文件路径；
- Swift client 只允许 `http://127.0.0.1:<port>` endpoint，并在 App 边界复核 request、track、package
  或完整 bundle identity；CompositionRoot 使用 v007 持久化的当前 catalog scope，Inspector 仅在用户
  显式点击后发送当前单图的既有预览。personal capability 的标签必须非空、唯一且全部对应当前 active
  个人标签；任何身份或标签不匹配都 fail closed；
- 签名 App 接线已按 Apple 的
  [`com.apple.security.network.client`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client)
  与 [`NSAllowsLocalNetworking`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)
  契约收敛 sandbox/ATS 配置；transport 仍由 Swift client 强制为 `127.0.0.1`，不得扩大为任意远端 HTTP；
- DINO/SigLIP/FastViT 的最终 App 内部署主线为
  `PyTorch → torch.jit.trace → coremltools.convert → ML Program`；DINOv2-small 已按固定
  `1×3×224×224 float32 → 1×384 float32` 输入/输出和 FP16 内部精度关闭首个转换门；
- artifact 加载必须核对 encoder/provider/model/preprocessing identity、转换格式、部署目标与模型目录
  SHA-256；现有 gate 为所有样本 cosine `>= 0.999` 且 relative L2 `<= 0.02`；
- Core ML HTTP provider 还必须核对固定 `1×3×224×224` 输入；artifact 缺失、身份/校验和/输入不匹配
  或 runtime 不可用时须在监听前失败，禁止自动回退 PyTorch 或 standard；
- Python 基准分别请求 `CPU_ONLY` 与 `ALL`。`ALL` 允许 Core ML 自选 CPU/GPU/Neural Engine；只读
  compute plan/resource 报告已区分 ALL 可运行与 ANE 计划证据，但不等于实际设备分配。实际 ANE
  调度、内存与热量另行关闭后，才可宣称 ANE；
- 首个 Core ML 版本通过后再独立评估 INT8 weight-only；
- Ollama 只作为可选 VLM adapter，用于描述或候选标签生成，不承担 encoder 训练，也不进入
  App 启动链路；Ollama 不可用不得改变其他 provider 的行为。

VLM 是模型类别而不是 runtime。若产品所有者原意为 MLX，则 MLX 作为后续 provider/runtime
实验接入；本文件定义的 HTTP、版本和失效契约不变。

### 2.3 双轨职责边界

- `standard`：输入图片，输出已发布 ontology 中的 concept ID、版本身份和原始 score；不依赖用户
  样本。只有批准的 policy revision 可以建议 App 写入 `autoAssigned`，否则进入 `suggested`；
- `personal`：输入图片或 embedding，使用当前目录库的个人 bundle，只输出 bundle 中已有的个人
  `tag_id`，并且永远是 `suggested`；
- 用户接受、拒绝、输入标签和最终有效标签解析都在 App 领域层完成。Python、Core ML 或 Ollama
  不得写目录库人工事实；
- 标准模型的训练数据和发布包不得包含用户目录库数据。标准标签纠错与个人标签样本分别导出、
  分别版本化，未经新的产品授权不得合并训练。

## 3. 公共 HTTP 契约

### 3.1 `GET /v1/health`

返回服务版本、`ready | degraded` 状态和已装载 provider identity。无 provider 时服务仍可启动，
但状态为 `degraded`。

### 3.2 `POST /v1/embeddings`

请求使用 JSON：

```json
{
  "request_id": "caller-generated-id",
  "image_base64": "...",
  "cache_key": {
    "schema_revision": 1,
    "catalog_scope_id": "canonical-lowercase-uuid",
    "asset_id": "canonical-lowercase-uuid",
    "content_revision": "7"
  }
}
```

`cache_key` 可省略；省略或服务未以 `--embedding-cache <sqlite-file>` 启动时行为与既有接口相同。
启用时，服务还把当前 provider 的 provider/model/revision/preprocessing/element count 全身份纳入主键；
catalog、asset revision 或 encoder 任一变化都必须 miss。缓存命中仍先验证当次 JPEG/PNG payload，
但不得再次调用 provider。坏库、坏向量、校验和错误或写入失败只退化为实时计算，不能使服务或旧
personal bundle 失效。

缓存落盘只包含 catalog/asset/content revision、完整 encoder identity、有限 little-endian float32
向量和向量 SHA-256；禁止保存原图、base64、路径、bookmark 或 image bytes。Swift client 已在用户
显式重建路径为每个唯一 asset revision 编码 `cache_key`；其他省略该字段的调用保持原行为。

响应至少包含：

```json
{
  "request_id": "caller-generated-id",
  "provider": "dinov2",
  "model_id": "facebook/dinov2-small",
  "model_revision": "ed25f3a31f01632728cabb09d1542f84ab7b0056",
  "preprocessing_revision": "dinov2-hf-autoimageprocessor-v1",
  "element_type": "float32",
  "element_count": 384,
  "embedding": []
}
```

服务拒绝空 payload、非法 base64、超过 20 MiB 的解码后数据和非 JPEG/PNG 输入。第一切片
显式只接收 JPEG/PNG；HEIC/HEIF/TIFF/WebP 在 App 侧形成批准的标准预览后再传入，不扩大
Python 解码面。

模型未配置返回稳定 `503 model_unavailable`；坏请求返回稳定 `422`。服务不得返回本机路径、
token、环境变量或内部异常栈。

### 3.3 `GET /v1/capabilities`

返回服务版本与 standard、personal 两条 suggestion 能力。任一轨道未加载时，其对象必须精确为
`{"status":"unavailable"}`。加载 standard package 后返回 pack ID/revision、原始 manifest bytes 的
SHA-256、ontology ID/revision、provider/model/preprocessing identity、mapping/policy revision 和已校验
weights SHA-256；App 必须先把这些字段与内置批准 package 全量核对，才可安装 ontology、读取图片或
入队 standard 全库任务。加载 personal bundle 后返回 catalog scope、bundle ID/revision、完整 encoder
identity、label vocabulary revision、权重 SHA-256、policy revision 和 bundle 内已有的 `tag_ids`；App
必须先验证 catalog scope 与当前目录库一致，且 `tag_ids` 非空、唯一并全部属于当前 active 个人标签，
才可发起 personal 请求。该接口不返回标签名称、训练样本、图片 locator 或权重内容。

### 3.4 `POST /v1/suggestions`

该接口统一承载双轨机器结果，但不返回“最终标签”。请求除 `request_id` 和 `image_base64` 外，
必须携带互斥 target：

```json
{
  "request_id": "caller-generated-id",
  "image_base64": "...",
  "target": {
    "track": "standard",
    "standard_pack_id": "imageall-public-v1",
    "standard_pack_revision": "..."
  }
}
```

个人请求把 target 替换为：

```json
{
  "track": "personal",
  "catalog_scope_id": "opaque-catalog-scope",
  "bundle_id": "opaque-personal-bundle",
  "bundle_revision": "...",
  "provider": "dinov2",
  "model_id": "facebook/dinov2-small",
  "model_revision": "...",
  "preprocessing_revision": "...",
  "element_count": 384,
  "label_vocabulary_revision": "...",
  "weights_sha256": "...",
  "policy_revision": "..."
}
```

服务加载 bundle 时核对 provider/model/preprocessing identity 和权重 SHA-256；请求时再精确核对
catalog、bundle ID/revision、encoder 五字段、标签词表、权重与 policy identity。缺失 bundle 返回 `503 personal_bundle_unavailable`，
请求身份不匹配返回 `409 personal_bundle_mismatch`，推理失败返回 `503 personal_model_failure`，均不得
回退 standard。响应使用 `request_id + suggestions[]` 包装；标准结果至少包含：

```json
{
  "request_id": "caller-generated-id",
  "suggestions": [
    {
      "track": "standard",
      "concept_id": "scene.beach",
      "tag_id": null,
      "score": 0.0,
      "recommended_state": "autoAssigned",
      "standard_pack_id": "imageall-public-v1",
      "standard_pack_revision": "...",
      "ontology_id": "imageall-public",
      "ontology_revision": "...",
      "provider": "provider-id",
      "model_revision": "...",
      "preprocessing_revision": "...",
      "mapping_revision": "...",
      "policy_revision": "..."
    }
  ]
}
```

`standard` 结果必须给出 `concept_id` 且 `tag_id = null`；`personal` 结果必须给出 `tag_id` 且
`concept_id = null`，其 `recommended_state` 固定为 `suggested`。App 先把标准 concept 映射为当前
已安装的本地标准 Tag，再应用人工覆盖规则；服务无权把 recommendation 写成 `manualAccepted`。
服务只返回 provider 直接命中的 concept；App 使用请求所指 package 的 ontology DAG 展开祖先，
并保留 `derivedFromConcept` 来源。自由文本、caption 和未发布词汇不得出现在 suggestions 数组中。
个人结果必须回传请求中的 catalog、bundle、encoder、标签词表、权重与 policy 完整身份；App 还要逐项
确认 `tag_id` 同时属于 capability 词表和当前 active 标签。标准专属的 package、ontology 和 mapping
字段为 `null`；personal 保留自身的 policy revision。没有结果时返回成功的空数组，不得用错误或
其他轨道的结果代替。

原始 score 不是概率，只能在同一 track、provider、model、preprocessing、mapping 和 policy revision
内使用。模型未就绪、标准包不匹配、个人 bundle 不存在或 revision 过期都返回稳定错误，不得退回
另一个 track 或静默使用旧版本。

### 3.5 `POST /v1/personal/rebuild`

该同步接口只在服务以 `--personal-store <path>` 启动时可用；managed store 与只读
`--personal-bundle` 互斥。请求在一次 HTTP 生命周期内完成输入验证、训练、候选 bundle 完整重载、
原子 active 切换和内存热重载：

```json
{
  "request_id": "canonical-lowercase-uuid",
  "expected_active_bundle": {
    "bundle_revision": "current-bundle-revision",
    "weights_sha256": "current-weights-sha256"
  },
  "snapshot": {
    "schema_revision": 1,
    "catalog_scope_id": "canonical-lowercase-uuid",
    "decision_snapshot_revision": "64-char-lowercase-sha256",
    "encoder": {
      "provider": "dinov2",
      "model_id": "facebook/dinov2-small",
      "model_revision": "...",
      "preprocessing_revision": "...",
      "element_count": 384
    },
    "personal_tag_ids": ["canonical-lowercase-uuid"],
    "label_vocabulary_revision": "64-char-lowercase-sha256",
    "embeddings": [
      {
        "asset_id": "canonical-lowercase-uuid",
        "content_revision": "1",
        "embedding": []
      }
    ],
    "decisions": [
      {
        "asset_id": "canonical-lowercase-uuid",
        "content_revision": "1",
        "tag_id": "canonical-lowercase-uuid",
        "state": "manualAccepted"
      }
    ]
  }
}
```

初次训练时 `expected_active_bundle` 为 `null`；已有 bundle 时必须把 capability 中当前
`bundle_revision + weights_sha256` 原样带回，形成 compare-and-swap 门。`content_revision` 是 canonical
非负十进制字符串；embedding row 以 `asset_id + content_revision` 唯一。snapshot 及其子对象禁止未知
字段，因此不能夹带 `image`、`image_base64`、路径、bookmark 或 bytes。原图只在此前单独调用
`/v1/embeddings` 时作为 loopback 临时 payload 出现。

服务再次执行 manual-only、encoder、UUID/SHA、词表唯一性和每标签 `2 accepted + 2 rejected` 门。
成功返回：

```json
{
  "request_id": "canonical-lowercase-uuid",
  "personal": {
    "status": "available",
    "catalog_scope_id": "...",
    "bundle_id": "...",
    "bundle_revision": "...",
    "encoder": {
      "provider": "dinov2",
      "model_id": "facebook/dinov2-small",
      "model_revision": "...",
      "preprocessing_revision": "...",
      "element_count": 384
    },
    "label_vocabulary_revision": "...",
    "weights_sha256": "...",
    "policy_revision": "...",
    "tag_ids": ["canonical-lowercase-uuid"]
  }
}
```

App 随后再次读取 `/v1/capabilities`，只在完整身份与响应相等时报告成功。无 managed store 返回
`503 personal_rebuild_unavailable`，active CAS 或 encoder/catalog 不匹配返回
`409 personal_bundle_mismatch`，非法 snapshot 返回 `422 invalid_personal_training_snapshot`，训练或发布
失败返回 `503 personal_rebuild_failed`。服务先在 store 内生成候选 bundle，完整校验后原子替换
`active.json`；失败时旧指针与旧内存 engine 保持不变。该最小切片不增加持久异步 job、progress 或
中途 cancel API；请求发出前可由 App 取消，发出后作为一次同步重建完成。

## 4. 标准 ontology/model package 契约（规划）

标准标签以可离线安装、校验和回滚的只读 package 发布：

```text
standard-pack/
├── manifest.json
├── ontology.json
├── mapping.json
├── policy.json
├── models/
└── LICENSES/
```

`manifest.json` 至少记录 package schema、ontology/model/preprocessing/mapping/policy revision、模型
权重 SHA-256、支持语言、许可证标识和文件校验和；`models/` 保存 manifest 明确引用的 provider
推理产物，不允许运行时按名称下载未打包权重。`ontology.json` 保存稳定 concept ID、本地化名称、
属性和 DAG edges；安装必须拒绝重复 ID、悬空 edge、跨 revision edge 和环。`mapping.json` 只允许把
固定 provider 输出映射到已存在 concept ID。`policy.json` 为每个概念记录丢弃、Review Queue 和
`autoAssigned` 门槛；没有独立校准证据的概念不得配置自动门槛。

package 不包含用户标签、人工决定、图片 locator、embedding 或个人模型权重。升级 package 时，
机器结果按完整 revision identity 失效；只有 manifest 显式声明语义未变的稳定 concept ID 才保留本地
别名和人工决定。概念拆分、合并或删除时归档旧绑定，不自动搬迁用户决定。

## 5. 个人训练产物契约

首切片实现的训练核心接受内存中的 `float32` embedding、标签词表和 0/1 多标签矩阵。后续个人训练
CLI 已把该能力收敛为稀疏人工决定快照和带 observation mask 的 loss；两个入口都不接受照片路径。
当前只用合成 embedding 验证 MPS/CPU 训练和 bundle 重载，不是生产照片准确率证据。

### 5.1 训练输入

`imageall-train-personal` 消费 ImageAll 显式导出的只读快照：

```text
training-input/
├── manifest.json
├── embeddings.npz
└── decisions.jsonl
```

`manifest.json` 记录 schema、opaque catalog scope ID、decision snapshot revision、encoder/provider/
preprocessing revision、embedding element count、个人 tag ID 稳定顺序和各文件 SHA-256。
`embeddings.npz` 以 `asset_id + content_revision` 对齐固定 embedding；`decisions.jsonl` 的每行只包含
`asset_id`、`content_revision`、`tag_id` 和 `manualAccepted | manualRejected`，同一 asset/tag 在快照中
必须唯一。

训练前必须验证每个决定只引用当前 manifest 中的个人 tag 和匹配 revision 的 embedding；未标注、
`autoAssigned` 和 `suggested` 不得进入 target。实现可以按标签训练独立二分类器，或使用带 observation
mask 的多标签 loss；无论哪种方式，缺失的 asset/tag pair 都必须从 loss 中排除，绝不能把 dense matrix
中的默认 `0` 解释为用户拒绝。

当前实现对每个个人 tag 保留既有 `2 + 2` 硬门；任一标签不足 2 个明确接受或 2 个明确拒绝时，CLI
返回失败且不创建 bundle。训练轮数和学习率必须为正数。

### 5.2 训练输出

训练输出为独立 bundle 目录：

```text
bundle/
├── manifest.json
└── linear-head.npz
```

`manifest.json` 使用稳定 JSON，至少记录：

- bundle schema revision；
- 固定 `track = personal`、不透明 catalog scope ID 和 decision manifest revision；
- encoder/provider identity；
- embedding element count；
- 个人 tag ID 稳定顺序、每标签正负样本数及 label vocabulary revision；
- suggestion policy revision、每标签 logit 阈值和最大返回数；
- loss、epochs、learning rate 和训练设备；
- `linear-head.npz` SHA-256。

原始 logits 只用于同一 provider、同一 bundle 内排序，不宣称为概率，不与 Vision Feature
Print margin、SigLIP 或 Ollama 输出横向比较。

同一 bundle 只属于一个 catalog scope。加载端必须校验 bundle、encoder、preprocessing、标签词表和
App 请求的完整 revision identity；任一不匹配都 fail closed，不得把其他目录库、用户或标准模型权重
作为回退。

## 6. TDD 矩阵

### 6.1 已关闭的首切片

按纵向顺序逐条 RED→GREEN：

1. 未装载 provider 时 health 为 degraded，embedding 请求返回稳定 503；
2. fake provider 接收一张合成 PNG，并返回完整版本 identity 和 float32 embedding；
3. 输入边界拒绝非法 base64、空数据、过大 payload 和非 JPEG/PNG；
4. 线性 head 用合成可分数据训练，在 MPS 可用时选择 MPS，产物 hash 可复核且重载结果一致；
5. DINOv2-small 固定 revision 对临时合成 PNG 生成 384 维有限向量。

### 6.2 双轨后续门

以下是阶段 5 的累计门，不要求由同一个切片一次关闭：1～4、7、9 属于标准场景 tracer，5～6 属于
个人训练 CLI，8 是所有后续切片共同回归门。

1. 标准 package 校验拒绝 DAG 环、悬空 concept、校验和错误和未记录许可证；
2. 零人工样本的公开 fixture 可以得到标准 concept suggestion；相同输入在没有 personal bundle 时
   不得得到个人 suggestion；
3. 标准 mapping 只返回已发布 concept ID，开放文本不能直接进入结果；
4. 达到批准 policy 门槛的标准结果建议 `autoAssigned`，个人结果永远建议 `suggested`；
5. decision manifest 拒绝未标注、机器结果、重复冲突决定和跨 catalog scope 数据；
6. 稀疏 decision manifest 的未观察 asset/tag pair 不参与 loss，也不计入负样本数；
7. 标准 direct concept 的 DAG 祖先展开保留 `derivedFromConcept`，人工操作只影响精确标签且不级联写事实；
8. 标准模型、个人 bundle 或 optional client 任一不可用时，现有 App 人工标注闭环仍能运行。
9. standard capability 不可用、字段畸形或完整 package identity 不匹配时，须在 ontology 安装、图片读取、
   全库入队和旧结果清理前 fail closed。

测试及 smoke 只使用临时目录和程序生成图片，不读取 `user/`、`/Volumes/HDD2` 或任何
`.photoslibrary`。

截至 `8b4cabc`，门 1～8 已在公开合成 fixture、合成 embedding 或签名 App 层关闭；个人 bundle 加载同时校验
catalog、bundle revision、DINO encoder、标签词表、policy 和权重身份，personal HTTP 只返回 bundle
内已有 tag 且固定为 `suggested`；标准 package 与 personal bundle 均可从固定 loopback CLI 装载，不再
依赖测试内注入。App 使用 v007 catalog scope 完成 capability、完整请求身份和逐条响应的三层核对，
只展示当前 active 个人标签；服务 unavailable、bundle/tag/identity 过期或未知时稳定关闭，原人工标注与
standard 预览继续可用。只有用户明确接受或拒绝后才写既有人工标签事务。Places365
revision、许可证、公开评测集和自动阈值校准仍是生产公共模型的独立准入门。用户触发重建现从
active 标签中只选择满足 `2 + 2` 的人工决定，每标签每角色最多取 12 条最新记录；App 为唯一资产
revision 请求 DINO embedding，确认快照未变化后同步 rebuild，并以 capability 二次确认。后端通过
managed store 的候选校验与原子 active 指针发布新 revision，任一失败保持旧 bundle。
每次 embedding 请求同时绑定当前 catalog scope、canonical asset UUID 与十进制 content revision；
后端再把当前完整 encoder identity 纳入缓存主键，身份或 revision 任一变化均 miss。
截至 `f8ea5e7`，App 还会把当前 capability 完整身份、active tag 词表与 personal prediction 分表
持久化；bundle 切换或明确 unavailable 会级联清理旧 personal 结果。全库扫描按 Asset ID 稳定分页、
单资产一次推理可返回多个 tag，结果与 Feature Print 重叠时审核队列去重并显示 personal provenance；
人工决定继续覆盖两条机器轨道。该 tracer 的进度仍只存在当前 App 会话，尚未复用持久 job checkpoint。
截至 `c2884d9`，v009 还持久化 standard pack/revision、ontology concept/DAG、公共模型身份与
`standard_tag_binding`。installer 只接受合法 DAG 和精确 package identity，重放幂等；环、revision 或
ontology identity 冲突整事务回滚。历史 Tag 不改 ID、不按名称绑定，缺少 binding 即保持 personal。
截至 `ce5dd34`，v010 新增 STRICT `standard_prediction`，标准结果必须匹配 active package、完整
model/ontology/mapping/policy identity、active standard Tag binding、当前可用 Asset 与精确
`content_revision`，否则整次替换回滚。结果状态固定为 `pendingReview`，`recommended_state` 只保留
模型建议语义，不直接写成人工事实；人工接受或拒绝继续覆盖机器结果。`1df422c` 把该发布事务接到
显式 Inspector 请求：请求前后复核同一内容 revision，持久化成功后才展示结果并刷新 Review Queue。
截至 `854745f`，v011 为既有 prediction 追加 nullable `derived_from_concept_id`，历史 v010 行自然保持
direct。仓储只沿请求已核对的 ontology DAG 向父节点递归：direct 命中优先于派生命中；多个派生来源
按同一模型身份下的 score、再按 concept ID 确定性去重；人工决定仍逐个精确 Tag 覆盖，不级联写事实。
截至 `b938019`，standard 全库建议也已接入统一持久任务：显式入队冻结 active source、catalog cutoff
与 standard pack identity，checkpoint 记录稳定 Asset ID 和检查/建议/跳过计数；启动恢复、暂停、继续、
取消、retryable 到期唤醒与 Activity 控制复用现有 runner。每项发布在同一 lease-protected 事务中同时
替换当前内容 revision 的 `standard_prediction` 并推进 checkpoint；服务、身份、内容或事务失败均
fail closed，已发布结果和人工决定不被清空。
截至 `d157487`，Backend 会从已完成 checksum/package 校验的 standard engine 导出完整 capability；
Swift client 对 available/unavailable 形状、嵌套 provider 字段与两个 SHA-256 做严格解码。Inspector
单图和 Review Overview 全库入口不再消费 CompositionRoot 硬编码 target，而是先取得 capability 并与
唯一批准 fixture 全量比对，再分别安装/读取/推理或入队；不匹配不会触碰既有结果。

### 6.3 Core ML FP16 门

`dfac6eb` 以纵向 RED→GREEN 关闭：

1. 合成 torch embedding 模型可原子导出 FP16 ML Program，manifest 固定输入/输出、部署目标和完整
   encoder identity；
2. identity 不匹配或 `.mlpackage` 任一内容改变时稳定拒绝加载；
3. CPU_ONLY 与 ALL 均返回数值门、预热/测量次数和 median/p95，且不得把 ALL 写成 ANE 已验证；
4. 固定 revision 的真实 DINOv2-small 先把 518 位置编码静态插值到产品 224 输入，静态 wrapper 与
   原始动态模型 FP32 输出一致，再完成 Core ML 转换；
5. 两张程序生成 RGB 图片经固定 AutoImageProcessor 后，两种 compute-unit 请求均通过 cosine 与
   relative L2 门。测试和转换产物只在临时目录，不读取任何真实照片。

`3a49774` 继续关闭 provider 门：

1. 真实临时 ML Program 经生成 PNG、固定 AutoImageProcessor 和公共 `EmbeddingProvider` 接口返回
   384 维有限向量，provider identity 与 artifact manifest 固定一致；
2. CLI 只接受 `--provider coreml --coreml-bundle <path>` 的成对配置，缺失、错配或不可加载时在监听前
   稳定退出；
3. `/v1/embeddings` 与 personal `/v1/suggestions` 复用既有响应和 bundle identity；personal 仍只输出
   bundle 内已有 `tag_id`、固定 `suggested`，Core ML 失败不回退 PyTorch 或 standard。

## 7. 后续切片

生产 standard 模型的完整状态机、Places365 候选档案、suggested-only 质量门和资源门见
[`STANDARD-MODEL-ADMISSION-SPEC.md`](./STANDARD-MODEL-ADMISSION-SPEC.md)。当前先实现不下载模型的
离线证据 verifier；只有官方权重字节、许可和公开数据 manifest verified 后，才另起 benchmark runner。

1. 标准场景 tracer：fixture 级闭环、完整 package capability 握手、v009 ontology/model identity、v010 standard prediction/Review Queue、显式 Inspector 发布、v011 祖先 DAG 展开与 standard 全库持久任务已完成；生产准入规格已冻结，Places365 ResNet18 当前为 `research`，实际评测、转换和批准仍待完成；
2. 个人训练：独立 CLI 与 App 用户触发的版本化 embedding/decision 快照、同步重建、原子发布和热重载
   已完成；后端版本化 embedding 持久缓存与 Swift 重建请求采用均已完成；personal 全库建议
   已通过持久 job/checkpoint、启动恢复、pause/resume/cancel 和 retryable 到期唤醒进入现有 Review
   Queue；自动后台重训仍明确延后；
3. `/v1/suggestions`：standard 与 personal 双轨、稳定错误、禁止跨轨回退及 CLI 装载已完成；
4. Core ML FP16：Python 转换、artifact 校验、数值一致性、CPU_ONLY/ALL 请求基准与只读 compute
   plan/resource 报告已完成；实际 Neural Engine 分配、内存与热量仍待独立验收；
5. Core ML provider：已完成；已验证 artifact 可装载为 Python 服务的可选 DINO embedding provider，
   保持 HTTP/personal bundle identity 和无跨 provider 回退不变；
6. Swift optional client：loopback transport、双轨严格解码、standard capability 全身份门、sandbox/ATS、显式 Inspector standard
   预览、personal capability/确认流、用户触发的 embedding/人工决定快照重建，以及 Review Overview
   显式刷新 `GET /v1/health` 的 ready/degraded/unavailable 状态已完成；不自动启动服务、创建标签、
   下载模型或在后台自动训练；
7. 再独立评估 SigLIP2、区域证据、FastViT student 和可选 Ollama VLM adapter。

Core ML Xcode 接线、SigLIP2 下载、Ollama 模型下载、生产 standard 模型
和真实照片人工验证都必须按独立切片重新冻结范围和验收门。

## 8. 禁止事项

- 不读取或写入受保护真实照片路径；
- 不遍历 `.photoslibrary`；
- 不让 Python/Ollama 成为 App 的链接、启动或数据库依赖；
- 不以 provider score 覆盖人工 accepted/rejected；
- 不把公共模型输出写成 `manualAccepted`，不把个人模型结果提升为 `autoAssigned`；
- 不把历史普通标签按名称自动绑定公开 concept，不把标准标签纠错混入个人训练 bundle；
- 不让 VLM、开放词表或自由文本直接创建 ontology concept 或用户个人标签；
- 不自动下载未固定 revision 或许可证未记录的模型；
- 不在本切片修改已有 migration、entitlement、privacy manifest 或 Xcode 工程；
- 不 push、不 amend、不清理或提交现有命令面板、App 图标、`design/`、`scripts/`、
  `Assets.xcassets/`、`user/` 等来源不明改动。

## 9. 实施与验收记录

| 交付 | Commit | 结果 |
|---|---|---|
| 架构、契约与阶段重排 | `31e256a` | 冻结独立模块、provider/version、HTTP、训练 bundle 与安全边界 |
| 首个实现切片 | `058a161` | loopback 服务、DINOv2-small、MPS 线性 head、锁定依赖与 12 项测试 |
| 标准 package 校验 | `c937299` | checksum、license、DAG、mapping、policy 和 package-root 安全门 |
| 标准场景 fixture tracer | `f51c666` | 固定 CC0 RGB 线性 fixture、零样本建议、policy 与祖先来源追溯 |
| standard suggestion HTTP | `61b29f5` | direct concept 响应、pack mismatch、无模块 degraded 与 personal 不回退 |
| 个人 DINO 训练 CLI | `abc5ef0` | 稀疏人工决定 mask、`2 + 2` 门、目录作用域 bundle、严格身份重载与独立 CLI |
| personal suggestion HTTP | `b92a01b` | policy v1、既有 tag-only、固定 `suggested`、完整身份 mismatch 与禁止 standard 回退 |
| 双轨服务启动 | `e447f80` | CLI 装载已校验 standard pack 或 DINO personal bundle，仍只绑定 loopback |
| Swift optional client tracer | `ffb1fd2` | 仅允许 `127.0.0.1`、双轨完整身份解码、跨 bundle fail closed、离线服务不回退 |
| DINOv2 Core ML FP16 | `dfac6eb` | 固定位置编码、原子 ML Program artifact、严格身份/checksum 与 CPU_ONLY/ALL 数值基准 |
| DINOv2 Core ML provider | `3a49774` | 固定预处理/输入、embedding 与 personal HTTP 复用、启动前 fail closed 且不跨 provider 回退 |
| Inspector 标准建议预览 | `c68a6aa` | CompositionRoot 固定公开 fixture 身份；显式单图请求、选择隔离、iCloud 已下载预览复用、离线 fail closed 与零持久化 |
| Inspector personal 建议确认 | `7e0ce5e` | v007 catalog scope、capability/active 标签核对、显式单图请求与接受/拒绝复用既有人工事务 |
| personal bundle 能力握手 | `972d42f` | 只读 capability、encoder/词表/权重/policy 完整身份二次核对、缺失/损坏 bundle 启动前稳定关闭 |
| personal bundle 原子重建 | `dae828b` | 同步 rebuild、严格 embedding/manual decision 快照、CAS、managed store、候选校验与失败保留旧 active |
| rebuild payload 对齐 | `3fa349c` | personal 专属 endpoint 去除冗余 track 字段，与 App 编码契约保持唯一 |
| App 用户触发重建 | `8b4cabc` | active 标签人工样本快照、每角色 12 条预算、DINO embedding、同步重建与 capability 二次确认 |
| 归档标签后重建 | `d717b3e` | 旧 bundle 可含已归档标签；仍以旧 revision/weights 做 CAS，并把新词表收敛到当前 active 标签 |
| 版本化 DINO embedding 缓存 | `ed90bcb` | 可选 SQLite cache、catalog/asset/content/encoder 精确主键、float32/checksum、损坏 miss 与 CLI 接入 |
| personal 全库 Review Queue | `f8ea5e7` | v008 capability/prediction 表、local-only 分页、多标签结果、二次身份门、跨 provider 去重与 provenance |
| Inspector 建议来源 | `c7eb0d2` | Inspector 列表区分个人 DINO 与 Feature Print，查询投影保持来源一致 |
| App DINO 缓存键采用 | `abeb442` | 重建 embedding 请求绑定 catalog/asset/content revision，无键调用保持兼容且不发送私有字段 |
| personal 全库持久任务 | `e728bcd` | capability 激活与 job 原子入队、checkpoint/启动恢复、Activity 控制、retryable 到期唤醒与旧结果保留 |
| Core ML compute plan 报告 | `23396a3` | 只读 execution plan/resource 报告，区分 ALL 可运行与 ANE 计划证据，无法取证时 fail closed |
| App 本地服务状态 | `ecb62bb` | 用户显式刷新 loopback health，严格校验 provider identity，展示 ready/degraded/unavailable 且不启动服务或下载模型 |
| 标准概念持久化基座 | `c2884d9` | v009 package/concept/DAG/model identity、稳定 Tag 绑定、同名命名空间隔离与原子幂等 synthetic installer |
| standard Review Queue | `ce5dd34` | v010 direct concept prediction、完整 package/model 身份门、人工覆盖、来源投影与事务 fail closed |
| Inspector standard 发布 | `1df422c` | 显式请求时惰性安装公开 fixture，绑定请求前后的内容 revision，持久化成功后才展示并刷新 Review Queue |
| 空闲 runner 刷新收敛 | `9c3abfe` | 无待处理任务时不刷新或覆盖 Review Queue；长任务仍按 300ms 周期投影进度 |
| standard ontology 祖先展开 | `854745f` | v011 direct/derived provenance、精确 revision recursive CTE、direct 优先与多来源确定性去重 |
| standard 全库持久任务 | `b938019` | 显式入队、local-only 稳定分页、pack/content revision 复核、事务发布/checkpoint、Activity 控制与安全重试 |
| standard package 能力握手 | `d157487` | 已验证 package 完整身份 discovery；单图/全库在任何安装、读图或入队前严格核准，畸形/不可用/mismatch fail closed |

2026-07-18 至 2026-07-19 验收：

- `uv sync --extra test` 在 `ModelBackend/.venv` 解析并安装锁定依赖，不修改全局 Python；
- `HF_HOME=/tmp/ImageAll-ModelBackend-HF IMAGEALL_RUN_MODEL_SMOKE=1 uv run pytest -q`：
  12 passed；测试仅使用程序生成 PNG 和合成 embedding；
- 独立 uvicorn 进程实际绑定 `127.0.0.1:18766`，HTTP 请求返回固定 DINOv2 revision、
  384 个有限 `float32` 元素，随后正常关闭；
- `uv build` 成功生成 sdist 和 wheel；
- `e447f80` 的已跟踪后端测试为 57 passed、1 skipped；两个 CLI help、Python compileall 与 `uv build`
  均通过，测试只使用临时目录、合成 embedding 和程序生成 PNG；
- `ffb1fd2` 的 Apple Development 签名 App 全量测试为 856 passed；client 定向 4 项与原有
  Feature Print/Photos 个性化 2 项共同通过，未把 client 注入 CompositionRoot；
- `c68a6aa` 的 Apple Development 签名 App 全量测试为 861 passed、0 failed、0 skipped；Inspector
  只在显式动作后调用固定 standard fixture，服务离线、身份失败或选择变化均不落库；构建产物的
  `NSAllowsLocalNetworking`、`com.apple.security.network.client` 与严格验签均通过；
- `7e0ce5e` 的 Apple Development 签名 App 全量测试为 869 passed、0 failed、0 skipped；personal
  capability 只接受当前 v007 catalog scope 和 active 标签 UUID，建议保持临时，用户明确接受/拒绝后
  才复用既有人工标签事务；arm64 Debug build、Apple Development 签名及 sandbox、network.client、
  Photos 与 bookmark entitlements 均通过；
- 从 `058a161` 导出的干净快照在不启动、不导入、不安装 `ModelBackend` 的情况下完成 unsigned
  arm64 Debug App build，结果为 `BUILD SUCCEEDED`；这证明当前 App 编译链不依赖模型模块；
- 工作区既有命令面板、App 图标、`design/`、`scripts/`、`Assets.xcassets/` 与 `user/`
  未进入上述两个提交；未访问 `/Volumes/HDD2` 或任何 `.photoslibrary`，未 push。

pytest 当前报告一条来自 FastAPI/Starlette `TestClient` 与未来 `httpx2` 迁移相关的弃用 warning；
它不影响本切片行为或构建，依赖升级时需单独消除，不能据此宣称未来版本兼容。

同日 fixture 级后续验收：`uv run pytest -q` 为 32 passed、1 skipped；跳过项仍是需显式开启的
DINOv2 真实模型 smoke。`uv build` 再次成功生成 sdist 与 wheel。三个实现提交均未修改 Swift、
Xcode、SQLite、个人训练入口或 console scripts；并行 App Icon 与个人训练草稿未进入提交。

同日个人训练 CLI 验收：`uv run pytest -q` 为 47 passed、1 skipped；`uv run
imageall-train-personal --help` 可用，`uv build` 成功。新增测试只使用临时目录和合成 embedding，未读取
图片、`user/`、`/Volumes/HDD2` 或 `.photoslibrary`。该提交未修改 Swift、Xcode 或 SQLite，也未接入
personal HTTP。

同日 personal suggestion HTTP 验收：personal 专项 23 passed，standard 专项 21 passed，全模块
`54 passed, 1 skipped`；跳过项仍是需显式开启的真实 DINOv2 smoke。两个 CLI 入口、Python 编译和
`uv build` 均通过。测试只使用临时目录、合成图片和 embedding，未读取 `user/`、`/Volumes/HDD2`
或 `.photoslibrary`；实现未修改 Swift、Xcode 或 SQLite，未 push。

同日 Core ML FP16 验收：`uv sync --extra test` 在 Darwin 安装可选 coremltools 工具链；同时显式启用
DINO provider 与 Core ML 两项生产 smoke 后，全模块为 `64 passed`。两张程序生成 RGB 图片的结果为：
CPU_ONLY minimum cosine `0.999882`、maximum relative L2 `0.015392`、median `7.39 ms`；ALL minimum
cosine `0.999950`、maximum relative L2 `0.010020`、median `2.75 ms`。约 41 MiB 的 `.mlpackage`
只生成在 pytest 临时目录；数值与延迟是当前 Mac 的小样本 tracer，不是发布性能结论，也未证明
ALL 实际使用 ANE。`imageall-convert-coreml --help`、Python compileall 与 `uv build` 通过；未修改
Swift、Xcode 或 SQLite，未读取 `user/`、`/Volumes/HDD2` 或 `.photoslibrary`，未 push。

同日 Core ML provider 验收：默认全模块为 `69 passed, 2 skipped`；使用
`HF_HOME=/tmp/ImageAll-ModelBackend-HF HF_HUB_OFFLINE=1` 并显式启用 DINO/Core ML 两项生产 smoke
后为 `71 passed`。真实固定 revision 完成 PyTorch embedding、FP16 转换/数值门和“程序生成 PNG →
固定 processor → Core ML provider → 384 维 embedding”路径；Python compileall、服务 CLI help 与
`uv build` 均通过。所有 artifact 仅生成在 pytest 临时目录，未读取 `user/`、`/Volumes/HDD2` 或
`.photoslibrary`，未修改 Swift、Xcode 或 SQLite，未 push。

同日 personal capability/完整身份握手验收：默认全模块为 `81 passed, 2 skipped`；使用
`HF_HOME=/tmp/ImageAll-ModelBackend-HF HF_HUB_OFFLINE=1` 并显式启用 DINO/Core ML 两项生产 smoke
后为 `83 passed`，standard 定向回归为 `21 passed`。Python compileall、服务 CLI help 与 `uv build`
通过。测试只使用 pytest 临时目录、合成图片和 embedding；未读取 `user/`、`/Volumes/HDD2` 或
`.photoslibrary`。实现提交以 App personal commit 为父提交，未夹带 App Icon、`design/`、`scripts/`
或 `user/`，未 push。

同日个人模型重建闭环验收：后端默认全量为 `93 passed, 2 skipped`，显式离线启用 DINO/Core ML
smoke 后为 `95 passed`，standard 专项为 `45 passed`；Python compileall、服务 CLI help 与 `uv build`
通过。App 对应 arm64 Apple Development 签名全量为 `875 passed, 0 failed, 0 skipped`，严格验签通过，
sandbox、network.client、Photos 与 bookmark entitlements 保持。测试只使用临时目录、合成 embedding
和程序生成图片；未读取 `user/`、`/Volumes/HDD2` 或 `.photoslibrary`，未 push。
归档标签替换的定向 App 回归为 `1 passed, 0 failed`；personal 推理仍要求 capability 词表全部 active，
只有显式 rebuild 路径允许旧 bundle 作为 CAS 基线后发布收敛词表。

同日版本化 embedding 缓存验收：cache 专项为 `14 passed`，默认后端全量为
`113 passed, 2 skipped`；`HF_HOME=/tmp/ImageAll-ModelBackend-HF HF_HUB_OFFLINE=1` 并显式启用
DINO/Core ML 两项 smoke 后为 `115 passed`。Python compileall、服务 CLI help（包含
`--embedding-cache`）与 `uv build` 通过。测试只使用临时 SQLite、合成 embedding 和程序生成 PNG；
未读取 `user/`、`/Volumes/HDD2` 或 `.photoslibrary`，未 push。该后端切片本身未修改 Swift；采用结果
见下。

同日 Swift 缓存键采用与跨组件验收：后端 cache/CLI 专项为 `27 passed`；App loopback transport 全组
及三条 personal rebuild 主/失败路径为 `13 passed`，Apple Development 签名全量为
`887 passed, 0 failed, 0 skipped`。请求只新增 schema/catalog/asset/content revision，不包含路径、
bookmark 或其他图片 locator；测试未读取 `user/`、`/Volumes/HDD2` 或 `.photoslibrary`，未 push。

同日 personal 全库 Review Queue tracer 验收：Apple Development 签名 App 全量为
`886 passed, 0 failed, 0 skipped`；严格 codesign 验证通过，Team Identifier 为 `962554J6D3`。
定向用例覆盖多标签单次推理、local-only/cloud-only 跳过、capability 二次核对、HTTP 409 bundle
mismatch、bundle 切换清理、人工覆盖、Feature Print 重叠去重和来源展示。测试仅使用合成目录库、
合成 preview bytes 与 loopback fake；未读取 `user/`、`/Volumes/HDD2` 或 `.photoslibrary`，未 push。

同日 personal 全库持久任务验收：相关回归为 `163 passed, 0 failed, 0 skipped`，Apple Development
签名 App 全量为 `900 passed, 0 failed, 0 skipped`；Debug build 与严格 codesign 验证通过，签名为
Apple Development、Team Identifier 为 `962554J6D3`。测试覆盖 active capability 与 job 原子写入、
同身份幂等复用、冲突不半写、同毫秒 active job 投影优先、启动恢复、异步 handler、未来
`not_before` 到期真实重试以及 foreground 不再逐图推理；未读取 `user/`、`/Volumes/HDD2` 或
`.photoslibrary`，未 push。

同日可选服务状态验收：Swift transport 与 Workspace 定向回归通过，Apple Development 签名 App
全量为 `905 passed, 0 failed, 0 skipped`；ModelBackend `/v1/health` 定向为 `1 passed`，Debug build
与严格 codesign 验证通过。状态检查只由用户显式触发，服务未运行或响应身份不完整时 fail closed，
不会启动 Python、下载模型、改写标签或读取受保护照片路径，未 push。

同日标准概念持久化基座验收：Apple Development 签名 App 全量为
`913 passed, 0 failed, 0 skipped`；Debug build 与严格 codesign 验证通过。v009 保持历史 `tag` DDL
和 ID 不变，以 `standard_tag_binding` 区分 standard/personal；synthetic package 重放幂等，DAG 环、
pack revision 和 ontology identity 冲突均不产生部分写入。同名个人/标准标签可并存，未读取
`user/`、`/Volumes/HDD2` 或 `.photoslibrary`，未 push。

同日 standard Review Queue 与 Inspector 发布验收：Apple Development 签名串行 App 全量为
`919 passed, 0 failed, 0 skipped`；Debug build 与严格 codesign 验证通过，Team Identifier 为
`962554J6D3`。定向用例覆盖显式请求、惰性 ontology 安装、持久化失败、选择变化与推理期间
`content_revision` 变化的 fail closed；空闲 personalization runner 不再异步覆盖已翻页的 Review
Queue，原不稳定导航用例连续 `5/5` 通过。测试只使用合成 fixture/preview，未读取 `user/`、
`/Volumes/HDD2` 或 `.photoslibrary`，未 push。

同日 standard ontology 祖先展开验收：Apple Development 签名串行 App 全量为
`921 passed, 0 failed, 0 skipped`；Debug build 与严格 codesign 验证通过。定向用例证明
`scene.water` 可沿固定 DAG 生成 `scene.outdoor` 与 `scene.environment`，派生行记录 direct concept；
父概念同时 direct/derived 时 direct 优先，多个派生来源确定性收敛。测试未读取 `user/`、
`/Volumes/HDD2` 或 `.photoslibrary`，未 push。

同日 standard 全库持久任务验收：相关 Swift 回归为 `170 passed, 0 failed, 0 skipped`，Apple
Development 签名串行 App 全量为 `929 passed, 0 failed, 0 skipped`；Debug build 与严格 codesign
验证通过。测试覆盖显式前台入队但不读取图片、local-only/cloud-only 分流、pack identity 与
`content_revision` 复核、发布/checkpoint 原子回滚、旧结果保留及 Activity 暂停；全部使用合成目录库
与 preview bytes，未读取 `user/`、`/Volumes/HDD2` 或 `.photoslibrary`，未 push。

同日 standard package capability 握手验收：Backend package/service 定向为 `48 passed`，默认全量为
`120 passed, 2 skipped`，compileall、sdist 与 wheel build 均通过；Apple Development 签名串行 App
全量为 `934 passed, 0 failed, 0 skipped`，Debug build 与严格 codesign 验证通过，Team Identifier 为
`962554J6D3`。定向用例覆盖 available/unavailable/畸形 capability、完整 package identity mismatch、
单图显式动作与全库入队前置门，失败路径确认零 ontology 安装、零图片读取、零任务入队且不清理旧结果。
全部测试使用公开 fixture、合成目录库与 preview bytes，未读取 `user/`、`/Volumes/HDD2` 或
`.photoslibrary`，未 push。
