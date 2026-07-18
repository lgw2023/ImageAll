# ImageAll 可选本地模型模块实施规格

> 状态：标准场景 fixture tracer 与 standard HTTP 已实现；个人训练和生产公共模型仍待后续门
> 日期：2026-07-18
> 开工基线：`main@14c3890b8c83c87a6f603c8900dfaabb3179ea6c`
> 范围：独立模型训练、部署与推理模块；本切片不接线 Xcode 工程或生产目录库

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
只证明版本化端到端契约，不是 Places365 或其他生产模型的准确率证据；CLI 安装入口、生产 schema、
Swift optional client 与真实照片验证均未接入。

## 2. 技术决策

### 2.1 训练与模型基准

- 训练/研究主线：PyTorch，设备优先级固定为 `mps → cpu`；
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
| Places365 ResNet18 | 标准场景标签、场景属性和 ontology mapping 的首个 tracer 候选 | 未批准；先关闭 revision、许可证、公开 fixture 和 Core ML 门 |
| DINOv2-small | 个人标签冻结 embedding | 固定 revision 的独立服务 tracer 已实现 |
| SigLIP2 B/32 256 | 开放词表与标准概念候选评测 | 后续 benchmark |
| SegFormer-B0 ADE20K | 水域、天空、道路等标准标签的区域证据 | 研究候选，不单独决定标签 |
| RAM++ | 通用对象/属性候选 | 许可证、权重来源和转换门未关闭，不得进入产品 |
| FastViT-T12/T8 | 公共高频标签稳定后的端侧 student | 后续蒸馏候选，不承担动态个人词表 |

### 2.2 推理与部署

- Python 服务只允许绑定 `127.0.0.1`；
- App 或测试向服务传递单张解码后图片 bytes，不传任意本机文件路径；
- DINO/SigLIP/FastViT 的最终 App 内部署主线为
  `PyTorch → torch.jit.trace → coremltools.convert → ML Program`；
- 首个 Core ML 版本先验证固定输入和 FP16 数值一致性，再独立评估 INT8 weight-only；
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
  "image_base64": "..."
}
```

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

### 3.3 `POST /v1/suggestions`（规划）

下一接口统一承载双轨机器结果，但不返回“最终标签”。请求除 `request_id` 和 `image_base64` 外，
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

个人请求把 target 替换为 `track = personal`、不透明 `bundle_id` 和 `bundle_revision`。响应使用
`request_id + suggestions[]` 包装；标准结果至少包含：

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
个人结果必须回传请求中的 `bundle_id + bundle_revision`；标准专属的 package、ontology、mapping 和
policy 字段为 `null`。没有结果时返回成功的空数组，不得用错误或其他轨道的结果代替。

原始 score 不是概率，只能在同一 track、provider、model、preprocessing、mapping 和 policy revision
内使用。模型未就绪、标准包不匹配、个人 bundle 不存在或 revision 过期都返回稳定错误，不得退回
另一个 track 或静默使用旧版本。

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

已实现的训练核心输入是内存中的 `float32` embedding、标签词表和 0/1 多标签矩阵；首切片不接受
照片路径。该合成全标注矩阵只证明 MPS 训练和 bundle 重载，不是稀疏用户反馈的生产输入。

### 5.1 训练输入（规划）

下一 CLI 消费 ImageAll 显式导出的只读快照：

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

以下是阶段 5 的累计门，不要求由同一个切片一次关闭：1～4、7 属于标准场景 tracer，5～6 属于
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

测试及 smoke 只使用临时目录和程序生成图片，不读取 `user/`、`/Volumes/HDD2` 或任何
`.photoslibrary`。

截至 `61b29f5`，门 1、2、3、7 和门 4 的 standard 半边已在公开合成 fixture 层关闭；personal
recommendation 的 `suggested` 约束须在个人 bundle 接入 HTTP 时继续关闭。门 8 当前只证明模块缺失时
服务保持 degraded 且既有 App 编译链不依赖模块，不等同于 Swift optional client 已实施。Places365
revision、许可证、公开评测集和自动阈值校准仍是生产公共模型的独立准入门。

## 7. 后续切片

1. 标准场景 tracer：fixture 级闭环已完成；生产公共模型 revision、许可证和校准仍待批准；
2. 个人训练 CLI：从 ImageAll 显式导出的版本化 embedding/decision manifest 训练并重载 bundle；
3. `/v1/suggestions`：standard 半边已完成；personal bundle 推理、固定 `suggested` 与 revision 错误待接入；
4. Core ML FP16：数值一致性、Xcode benchmark、Neural Engine/内存/热量记录；
5. Swift optional client：默认关闭，把标准自动结果与个人建议接入现有查询和 Review Queue；
6. 再独立评估 SigLIP2、区域证据、FastViT student 和可选 Ollama VLM adapter。

Core ML 转换、SigLIP2 下载、Ollama 模型下载、生产数据库接线和真实照片人工验证都必须按
独立切片重新冻结范围和验收门。

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

2026-07-18 验收：

- `uv sync --extra test` 在 `ModelBackend/.venv` 解析并安装锁定依赖，不修改全局 Python；
- `HF_HOME=/tmp/ImageAll-ModelBackend-HF IMAGEALL_RUN_MODEL_SMOKE=1 uv run pytest -q`：
  12 passed；测试仅使用程序生成 PNG 和合成 embedding；
- 独立 uvicorn 进程实际绑定 `127.0.0.1:18766`，HTTP 请求返回固定 DINOv2 revision、
  384 个有限 `float32` 元素，随后正常关闭；
- `uv build` 成功生成 sdist 和 wheel；
- 从 `058a161` 导出的干净快照在不启动、不导入、不安装 `ModelBackend` 的情况下完成 unsigned
  arm64 Debug App build，结果为 `BUILD SUCCEEDED`；这证明当前 App 编译链不依赖模型模块；
- 工作区既有命令面板、App 图标、`design/`、`scripts/`、`Assets.xcassets/` 与 `user/`
  未进入上述两个提交；未访问 `/Volumes/HDD2` 或任何 `.photoslibrary`，未 push。

pytest 当前报告一条来自 FastAPI/Starlette `TestClient` 与未来 `httpx2` 迁移相关的弃用 warning；
它不影响本切片行为或构建，依赖升级时需单独消除，不能据此宣称未来版本兼容。

同日 fixture 级后续验收：`uv run pytest -q` 为 32 passed、1 skipped；跳过项仍是需显式开启的
DINOv2 真实模型 smoke。`uv build` 再次成功生成 sdist 与 wheel。三个实现提交均未修改 Swift、
Xcode、SQLite、个人训练入口或 console scripts；并行 App Icon 与个人训练草稿未进入提交。
