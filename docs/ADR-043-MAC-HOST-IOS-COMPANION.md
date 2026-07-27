# ADR-043：Mac Host + 原生 iOS Companion（辅助客户端）

> 状态：已决定（2026-07-27，项目所有者对话批准）  
> 相关：`user/Mac Host  原生 iOS Companion.md`、`user/合并 MacOS 端 IOS端代码仓.md`（想法来源；以本 ADR 为准）  
> 角色边界：本文锁定产品/架构决策；可执行实现按切片交付，不与本 ADR 混在同一 commit

## 背景

所有者需要在手机上浏览图库、打标签与审核建议，但：

- Mac App 仍是唯一主产品；
- iOS 端现阶段只作为辅助开发/自用工具，不作为主产品；
- 不希望大改现有 Mac UI / 主路径；
- 明确不做 Tailscale 远程桌面验证路线。

现有 `LibraryWorkspacePort` 已接近远程 API 面，但混合了大量 Mac 专属管理能力；`LibraryWorkspace` UI 依赖 AppKit，不能直接编译到 iOS。

## 决策

### 1. 产品形态

| 角色 | 定位 |
|---|---|
| ImageAll Mac | 唯一权威主机：GRDB、PhotoKit、文件夹授权、Core ML、Job Queue、派生图 |
| ImageAll Mobile | 辅助 Companion：远程浏览、筛选、标签决定、建议审核、任务只读/有限动作 |
| 仓库 | **同仓 monorepo**；共享 `ImageAllRemoteProtocol`；初期不拆独立 Git 仓 |

### 2. Mac 改动白名单（硬约束）

允许：

- 新增 `Packages/ImageAllRemoteProtocol`（及后续 Client package）；
- 新增 Remote Application / Infrastructure（Facade、HTTP Host、开发期鉴权）；
- 增加 `com.apple.security.network.server`；
- 在 `CompositionRoot`（或等价装配点）挂载 Host，**不经过** `LibraryWorkspaceModel`；
- 默认关闭或仅开发开关开启；可用 `defaults` / 环境变量启用，R0 不强制改 Mac UI。

禁止（本阶段）：

- 拆分重构 `LibraryWorkspacePort`（可在后续单独切片评估）；
- 改写 `LibraryWorkspace` / ViewModel 主交互以迁就远程；
- 把工程大迁到 `Apps/ImageAllMac` 目录树；
- 同步 SQLite 到手机、iCloud Drive 同步库、WebRTC 首版、自建 Relay 首版；
- 让 iOS 直接 `import` Mac Application/Infrastructure 实现。

### 3. 通信与权威

- Mac 永远是唯一写权威；手机只发命令并消费投影 DTO。
- R0/R1：局域网 HTTP（可先明文 + 开发 token；TLS/配对后置）。
- 查询与图片走 HTTP；实时事件 / WebSocket 后置。
- 批量标签必须带幂等 `operationId`。
- 缩略图请求带目标像素；R0 可先忽略尺寸并返回现有派生缩略图，但协议字段必须预留。

### 4. iOS 范围（辅助工具）

首批：**来源列表、资产分页网格、缩略图、标签 accept/reject/clear、能力探测**。  
明确留在 Mac：连接文件夹/Photos、存储位置、导出、缓存清理、训练高级设置、瘦身回收等 HostAdministration。

### 5. 实施切片

| 切片 | 内容 | 停止位置 |
|---|---|---|
| **R0** | ADR + Remote Protocol Package + Mac 薄 Facade/HTTP Host + 单测；不改 Mac UI；不建完整 iOS App | Host 可对 capabilities/sources/assets/thumbnail/tag-batch 响应 |
| **R1** | 最小 iOS target/壳 + Remote Client，连本机 Host | 手机/模拟器能看网格并改标签 |
| **R2+** | Bonjour、正式配对、TLS、WebSocket 事件、异地中继 | 另开 ADR/切片 |

### 6. 版本与兼容

- App 版本可独立；协议用 `protocolVersion` + `capabilities`。
- 同仓原子改协议；不强制 Mac/iOS 同号发布。

## 后果

- `ARCHITECTURE.md` §3.2「不在 MVP 中实现 iPhone/iPad 客户端」改为：MVP 主产品仍为 Mac；Companion 按 ADR-043 辅助切片推进，不阻塞 Mac 主路径。
- 测试必须覆盖：DTO round-trip、Facade 映射、Host 鉴权失败、幂等 operationId；不得读取受保护真实照片路径。
- 现有未提交的 `LibraryWorkspace*` 草稿与本能力无交集，实施时必须保留。

## 反例

- 不得为了 iOS 把 `LibraryWorkspaceModel` 改成网络入口。
- 不得让手机直接打开或复制 Mac catalog DB。
- 不得在 R0 引入工程大搬家或双仓协议漂移。
- 不得把远程桌面/VNC 写成产品依赖。
