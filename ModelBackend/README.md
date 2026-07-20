# ImageAll ModelBackend

`ModelBackend` 是 ImageAll 的模型转换、离线评测和开发验证工具，不属于 Xcode target，也不随正式
App 分发。普通用户运行模型不需要 Python、`uv`、loopback HTTP、helper/XPC 或本目录的 `.venv`；
正式 App 由 Swift 在 App 容器内校验并直接加载 Core ML artifact。未启用模型、artifact 缺失/损坏或
初始化失败时，不影响浏览、人工标签、标签预设和传统个性化建议。

当前模块包含：

- 固定 revision 的 `facebook/dinov2-small` PyTorch/Core ML embedding provider；
- 仅监听 loopback 的 FastAPI/uvicorn 服务；
- 合成 embedding 上可使用 MPS 的线性多标签 head 训练与可复核 bundle；
- 可由启动命令装载的标准 package 与 catalog-scoped personal bundle；
- personal bundle 的只读 capability 握手与完整身份 fail-closed 推理；
- 用户触发的 embedding/人工决定快照训练、原子 personal bundle 发布与热重载；
- 可选的 catalog/asset/content revision/encoder 全身份 embedding 持久缓存；
- fake provider、输入边界、训练重载和真实 DINOv2 smoke 测试。

## 开发环境安装

需要 Python 3.11～3.13 和 `uv`：

```bash
cd /Volumes/SSD1/ImageAll/ModelBackend
uv sync --extra test
```

依赖安装在 `ModelBackend/.venv`，不会修改全局 Python 环境。版本由 `uv.lock` 固定。
只安装运行时 Core ML 可选依赖时使用 `uv sync --extra coreml`。

## 开发验证服务（不随 App 分发）

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
  --embedding-cache /absolute/path/to/imageall-embeddings.sqlite3 \
  --offline \
  --port 8765
```

`--model-cache` 保存固定模型文件；`--embedding-cache` 是独立、可删除和可选的计算结果缓存。只有
`POST /v1/embeddings` 同时携带 schema revision、catalog scope UUID、asset UUID 和十进制
`content_revision` 时才尝试复用；实际主键还绑定当前 provider 的完整 encoder identity。任一身份或
revision 变化、校验和不匹配、数据库损坏或不可写都按 cache miss 处理，并回到当前 provider 计算。
SQLite 只保存上述身份、有限 float32 向量和向量 SHA-256，不保存原图、base64、路径或 bookmark。
不配置该参数时原接口行为不变。

先转换固定 DINOv2 revision 并生成带校验 manifest 的 FP16 artifact：

```bash
uv run imageall-convert-coreml \
  --output /absolute/path/to/dinov2-small-coreml \
  --model-cache /absolute/path/to/huggingface/hub \
  --offline
```

开发时可再把该 artifact 装载为 HTTP embedding provider，用于 parity 和接口回归；正式 App 不走此路径：

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

发布前可用独立启动验收器验证“进程启动 → loopback health/capability → 程序生成 PNG 请求 →
确定性关闭”。验收器不经过 shell 执行目标 argv，只允许 `127.0.0.1`，输出不会记录完整命令或路径：

```bash
uv run imageall-verify-service-startup \
  --endpoint http://127.0.0.1:18773 \
  --expected-health ready \
  --probe-kind embedding \
  --output /tmp/imageall-service-startup.json \
  -- .venv/bin/imageall-model-backend \
    --provider coreml \
    --coreml-bundle /absolute/path/to/verified-compiled-coreml \
    --model-cache /absolute/path/to/huggingface/hub \
    --offline \
    --port 18773
```

`control` 只验 health/capability，`embedding` 额外核对完整 provider identity、384 维有限 float32
结果，`standard` 则从已验证 standard capability 构造 target 并发送程序生成蓝色 PNG。成功或失败都先
terminate，超时才 kill，并把是否仍有子进程写入证据。该命令是一次性发布门，不负责常驻服务或 App
内自动启动。目标应是当前环境中直接安装的 `imageall-model-backend` console executable；不要再套一层
`uv run`，否则验收器只能管理包装进程而不能证明实际服务已退出。

加载仓库内的标准场景公开 fixture：

```bash
uv run imageall-model-backend \
  --standard-pack fixtures/standard-scene-pack-v1 \
  --port 8765
```

在安装或启动标准 pack 前，可以先做只读预发布校验：

```bash
uv run imageall-validate-standard-pack \
  --pack fixtures/standard-scene-pack-v1
```

校验会复用服务实际使用的严格 loader，检查文件校验和、许可证登记、ontology DAG、mapping、policy
与完整版本身份；成功时只输出不含路径的稳定 JSON 摘要，失败时返回退出码 2 且不启动服务、不下载或
激活模型。校验通过只证明 pack 契约完整，不等于批准其许可证、准确率、阈值校准或生产使用。

生产 standard 候选还要通过独立 evidence verifier。仓库内 Places365 报告只记录公开来源元数据，不含
权重或图片，并应稳定保持 `research`：

```bash
uv run imageall-verify-standard-admission \
  --report fixtures/standard-admission/places365-resnet18-research-v1.json
```

输出状态为 `approvedSuggestedOnly` 时退出 0；`research`、`evaluationReady` 或 `rejected` 时退出 2；
畸形报告退出 3。verifier 不下载、转换或运行模型，也不会生成 standard pack。

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

要允许 App 用户显式重建并热切换个人模型，改用 managed store；它与只读
`--personal-bundle` 互斥：

```bash
uv run imageall-model-backend \
  --provider dinov2 \
  --personal-store /absolute/path/to/personal-store \
  --model-cache /absolute/path/to/huggingface/hub \
  --offline \
  --port 8765
```

空 store 可以启动，此时 capability 为 unavailable。同步 `POST /v1/personal/rebuild` 只接收版本化
embedding 与 `manualAccepted | manualRejected` 决定，不接收原图、路径或 bookmark。服务严格核对
catalog、encoder、标签 UUID 词表、`2 + 2` 样本门和当前 active bundle CAS；候选训练并完整重载校验后，
才原子替换 `active.json` 并热切换内存 engine。校验、训练或发布失败时旧 bundle 继续生效，且不回退
standard。

App 在请求个人建议前先读取当前服务能力：

```bash
curl http://127.0.0.1:8765/v1/capabilities
```

未加载个人 bundle 时 `personal.status` 为 `unavailable`。加载后响应只公开 catalog scope、bundle、
encoder、标签 UUID 词表 revision、权重 SHA-256、policy revision 和 bundle 内已有的 `tag_ids`；不公开
标签名称、训练样本或权重内容。personal `/v1/suggestions` 必须原样带回这份完整身份，任一字段缺失或
不匹配都返回 `409 personal_bundle_mismatch`，且不会回退 standard。

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

仓库中的 Swift loopback client、HTTP suggestion/rebuild 与服务状态页面属于既有实验实现和回归资产，
不再作为正式部署方向继续扩展。新的纵向切片是“程序生成图片 → App 内校验固定 Core ML artifact →
Swift 直接推理 → 有限且身份匹配的 embedding”，并证明未启用、缺失或损坏时安全降级。个人模型后续
优先在 App 内复用 DINO encoder 和轻量线性 head。生产标准模型仍须独立关闭许可证、公开数据、parity
与资源门；原始 `.pth.tar`、本目录 Python 包和 loopback 服务永远不得进入正式 App bundle。
