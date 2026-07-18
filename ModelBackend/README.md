# ImageAll ModelBackend

`ModelBackend` 是 ImageAll 的可选本地模型进程。它不属于 Xcode target；未安装、未启动或
模型不可用时，不影响原 App 的浏览、人工标签、标签预设和传统个性化建议。

当前模块包含：

- 固定 revision 的 `facebook/dinov2-small` PyTorch/Core ML embedding provider；
- 仅监听 loopback 的 FastAPI/uvicorn 服务；
- 合成 embedding 上可使用 MPS 的线性多标签 head 训练与可复核 bundle；
- 可由启动命令装载的标准 package 与 catalog-scoped personal bundle；
- fake provider、输入边界、训练重载和真实 DINOv2 smoke 测试。

## 安装

需要 Python 3.11～3.13 和 `uv`：

```bash
cd /Volumes/SSD1/ImageAll/ModelBackend
uv sync --extra test
```

依赖安装在 `ModelBackend/.venv`，不会修改全局 Python 环境。版本由 `uv.lock` 固定。
只安装运行时 Core ML 可选依赖时使用 `uv sync --extra coreml`。

## 启动

先验证无模型降级服务：

```bash
uv run imageall-model-backend --provider none --port 8765
curl http://127.0.0.1:8765/v1/health
```

首次启动 DINOv2 会从 Hugging Face 下载固定 revision：

```bash
uv run imageall-model-backend --provider dinov2 --port 8765
```

使用已存在的独立缓存并禁止联网：

```bash
uv run imageall-model-backend \
  --provider dinov2 \
  --model-cache /absolute/path/to/huggingface/hub \
  --offline \
  --port 8765
```

先转换固定 DINOv2 revision 并生成带校验 manifest 的 FP16 artifact：

```bash
uv run imageall-convert-coreml \
  --output /absolute/path/to/dinov2-small-coreml \
  --model-cache /absolute/path/to/huggingface/hub \
  --offline
```

再把该 artifact 装载为 HTTP embedding provider：

```bash
uv run imageall-model-backend \
  --provider coreml \
  --coreml-bundle /absolute/path/to/dinov2-small-coreml \
  --model-cache /absolute/path/to/huggingface/hub \
  --offline \
  --port 8765
```

`--provider coreml` 与 `--coreml-bundle` 必须同时出现。artifact identity、checksum 或固定输入契约
不匹配时服务在监听前停止，不会回退到 PyTorch provider。

加载仓库内的标准场景公开 fixture：

```bash
uv run imageall-model-backend \
  --standard-pack fixtures/standard-scene-pack-v1 \
  --port 8765
```

加载 `imageall-train-personal` 生成的个人 bundle：

```bash
uv run imageall-model-backend \
  --provider dinov2 \
  --personal-bundle /absolute/path/to/personal-bundle \
  --model-cache /absolute/path/to/huggingface/hub \
  --offline \
  --port 8765
```

个人 bundle 可与 PyTorch 或 Core ML DINO provider 配合，但必须与启动时实际装载的 provider identity
完全一致；缺少 provider 或身份不匹配时
服务在监听端口前停止。标准 fixture 只验证 package、mapping、policy 与 HTTP 契约，不代表生产模型准确率。

CLI 不提供 host 参数，服务固定绑定 `127.0.0.1`。接口契约见
[`docs/LOCAL-MODEL-MODULE-SPEC.md`](../docs/LOCAL-MODEL-MODULE-SPEC.md)。

## 验证

默认测试不下载模型：

```bash
uv run pytest -q
```

真实 DINOv2 smoke 使用程序生成的 PNG；建议把首次下载限制在显式临时缓存：

```bash
HF_HOME=/tmp/ImageAll-ModelBackend-HF \
IMAGEALL_RUN_MODEL_SMOKE=1 \
uv run pytest -q
```

构建 Python 发布包：

```bash
uv build
```

仓库已有 Swift loopback client 与显式单图 standard 预览，但仍没有个人 bundle App 接线、数据库持久化、
模型自动安装、生产标准模型、SigLIP2 或 Ollama adapter；Core ML 的 Xcode compute plan、实际 ANE、
内存与热量仍由独立后续切片验收。
