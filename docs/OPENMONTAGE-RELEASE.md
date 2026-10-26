# ImageAll / OpenMontage 发布与恢复

## 版本与构建

`integration-contract.json` 是集成契约的唯一来源。修改支持格式时：

```sh
python3 -B scripts/openmontage/integration_contract.py --generate
```

Swift 导出/握手引用生成常量；Python 补丁引用同一清单。构建检查 Schema、lock、两种 envelope 的故事身份、导演版本及生成代码。不能只改某处哈希绕过校验。

`build_payload.py` 在构建私有目录从已校验的源码归档重新生成 engine，依赖取自已准备的 Runtime。输入脚本先冻结为快照，防止并行会话修改造成一次构建混入两个版本；共享 Runtime 不再被 embed 修改。输入身份缓存与最终全部 payload 内容身份分开。helper 安装后核对关键源码/Schema 清单；缓存损坏时拒绝启动。

源码快照、清单、运行产物均保留在构建私有目录；用户任务、模型配置、凭据不进入该缓存。当前仍为本机 arm64 构建，依赖准备沿用 prepare.py。

## 日常发布

在仓库根执行；证据目录必须每轮新建。示例使用占位路径：

```sh
python3 -B scripts/openmontage/release.py \
  --evidence /absolute/path/to/new-release-evidence \
  --previous-app /absolute/path/to/current/ImageAll.app \
  --packages /absolute/path/to/existing/SourcePackages
```

默认构建并暂存已验证 App，不启动生产 Photos 测试宿主。顺序为：

1. build-for-testing；复制构建快照，避免其他构建改变正在验收的 App。
2. 独立 xctest 加载 debug dylib，验证离线恢复、状态不确定、冻结重试、防重复、拒绝处理、诊断脱敏。
3. 旧随包执行器处理 Swift 发布的合成任务；渲染中调用新 helper，验证正常完成后升级及新 PID/运行目录。
4. 新执行器完成普通制作、固定模板；随包 Python 通过本机 loopback 模型 fixture，绝不调用付费模型。
5. 停止执行器后，由 Swift 客户端读取和验证成片，证明恢复不依赖在线状态。
6. 移除生产发布包中的测试 PlugIns，重新签名并核对被测主动态库与 helper 版本，生成包含整包内容身份的 release.json。

可以用 `--built-app` 指定刚完成的 build-for-testing 产物。该选项只省略构建，不省略验收。

退出正在运行的日常 App 后，安装已验收产物：

```sh
python3 -B scripts/openmontage/install_verified.py \
  --release /absolute/path/to/new-release-evidence/release.json \
  --destination /absolute/path/to/daily/ImageAll.app
```

可重复指定 destination 更新多个日常入口。安装前复核整包内容身份和严格签名；拒绝覆盖正在运行的目标。先在目标旁暂存新 App，再切换，原 App 保留到证据目录。任一门禁失败都不替换日常 App。也可直接向 release.py 添加 `--install-to` 合并最后一步。

## 运行与恢复规则

普通渲染、模板制作、自动可编辑创作均先通过同一启动协调器，同根目录并发启动合并。旧版本活动工作正常排空，等待超时明确报错，不强杀或取消；再次操作仍会核对版本。模型调用保留逐次授权，不自动重发。

历史成片独立于执行器在线状态。观测失败时，制作面板隐藏旧百分比并显示“状态待确认”，继续限制重复提交。重新连接只恢复观测和执行器，不新建制作。

仅明确失败或取消的本地制作显示“用原素材重试本地制作”。重试重新核对冻结清单与每个文件哈希，复制已发布副本，不读取源照片；新任务通过完整完成记录发布并记录 retryOfTaskID。原终态和素材不改。损坏素材、活动任务、未知状态、旧格式不兼容均拒绝重试。

“保存制作诊断”导出版本、协议摘要、状态/阶段、序号及受限错误码；不复制原请求、原始错误全文、目录路径、照片、密钥或提示词。未知的模型请求结果仍须人工判断是否重新发起，不能用渲染重试代替模型授权。
