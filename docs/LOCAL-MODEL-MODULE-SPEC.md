# ImageAll 可选本地模型模块实施规格

> 状态：First tracer slice implemented
> 日期：2026-07-18  
> 开工基线：`main@14c3890b8c83c87a6f603c8900dfaabb3179ea6c`  
> 范围：独立模型训练、部署与推理模块；本切片不接线 Xcode 工程或生产目录库

## 1. 目标与停止位置

本模块为 ImageAll 提供可替换的本地视觉模型能力，但不是 App 的启动依赖。模块未安装、
服务未启动、权重缺失或单次预测失败时，App 仍须保留浏览、人工标签、标签预设和现有
Vision Feature Print 个性化建议闭环。

第一条 tracer slice 只完成：

```text
合成图片 bytes
→ loopback HTTP 推理契约
→ DINOv2-small embedding
→ 版本化预测响应
```

同时提供一个可在 Apple Silicon 上运行的线性多标签 head 训练核心，以预计算 embedding
作为输入。第一切片停止于独立模块测试和合成图片真实 embedding smoke；不修改 Swift、
Xcode 工程、SQLite schema 或 App UI，不下载 SigLIP2、DINOv3、FastViT 或 Ollama VLM 权重。

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

## 4. 训练产物契约

线性 head 的公开训练输入是内存中的 `float32` embedding、标签词表和 0/1 多标签矩阵；
首切片不接受照片路径。训练输出为独立 bundle 目录：

```text
bundle/
├── manifest.json
└── linear-head.npz
```

`manifest.json` 使用稳定 JSON，至少记录：

- bundle schema revision；
- encoder/provider identity；
- embedding element count；
- 标签稳定顺序及 label vocabulary revision；
- loss、epochs、learning rate 和训练设备；
- `linear-head.npz` SHA-256。

原始 logits 只用于同一 provider、同一 bundle 内排序，不宣称为概率，不与 Vision Feature
Print margin、SigLIP 或 Ollama 输出横向比较。

## 5. 首切片 TDD 矩阵

按纵向顺序逐条 RED→GREEN：

1. 未装载 provider 时 health 为 degraded，embedding 请求返回稳定 503；
2. fake provider 接收一张合成 PNG，并返回完整版本 identity 和 float32 embedding；
3. 输入边界拒绝非法 base64、空数据、过大 payload 和非 JPEG/PNG；
4. 线性 head 用合成可分数据训练，在 MPS 可用时选择 MPS，产物 hash 可复核且重载结果一致；
5. DINOv2-small 固定 revision 对临时合成 PNG 生成 384 维有限向量。

测试及 smoke 只使用临时目录和程序生成图片，不读取 `user/`、`/Volumes/HDD2` 或任何
`.photoslibrary`。

## 6. 后续切片

1. 基准工具：在公开可分发 fixture 上比较 DINOv2-small、SigLIP2 与现有 Feature Print；
2. 多标签训练 CLI：从 ImageAll 显式导出的、版本化 embedding/decision manifest 训练 head；
3. Core ML FP16：数值一致性、Xcode benchmark、Neural Engine/内存/热量记录；
4. 可选 Ollama VLM adapter：严格 JSON schema、超时、取消和无服务降级；
5. Swift optional client：只有上述门通过后才接线 Composition Root，默认关闭且无服务零影响。

Core ML 转换、SigLIP2 下载、Ollama 模型下载、生产数据库接线和真实照片人工验证都必须按
独立切片重新冻结范围和验收门。

## 7. 禁止事项

- 不读取或写入受保护真实照片路径；
- 不遍历 `.photoslibrary`；
- 不让 Python/Ollama 成为 App 的链接、启动或数据库依赖；
- 不以 provider score 覆盖人工 accepted/rejected；
- 不自动下载未固定 revision 或许可证未记录的模型；
- 不在本切片修改已有 migration、entitlement、privacy manifest 或 Xcode 工程；
- 不 push、不 amend、不清理或提交现有命令面板、App 图标、`design/`、`scripts/`、
  `Assets.xcassets/`、`user/` 等来源不明改动。

## 8. 实施与验收记录

| 交付 | Commit | 结果 |
|---|---|---|
| 架构、契约与阶段重排 | `31e256a` | 冻结独立模块、provider/version、HTTP、训练 bundle 与安全边界 |
| 首个实现切片 | `058a161` | loopback 服务、DINOv2-small、MPS 线性 head、锁定依赖与 12 项测试 |

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
