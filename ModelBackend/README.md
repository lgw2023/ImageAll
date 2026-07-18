# ImageAll ModelBackend

`ModelBackend` 是 ImageAll 的可选本地模型进程。它不属于 Xcode target；未安装、未启动或
模型不可用时，不影响原 App 的浏览、人工标签、标签预设和传统个性化建议。

当前模块包含：

- 固定 revision 的 `facebook/dinov2-small` embedding provider；
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

个人 bundle 必须与启动时实际装载的 DINO provider identity 完全一致；缺少 provider 或身份不匹配时
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

当前没有 Swift client、数据库接线、模型自动安装、生产标准模型、SigLIP2 或 Ollama adapter；
Core ML 工作由独立后续切片验收。
这些能力按规格中的独立后续切片实施。
