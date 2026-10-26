# 系统盘模拟器与 OpenMontageRuntime 迁移排期

日期：2026-10-13。状态：**用户已授权；已纳入后续工作，尚未复制、切换或清除源副本**。

## 范围与时机

用户通过“清理旧 Codex 目录”聊天传达并在本聊天明确授权以下两项迁移。该清理聊天没有修改源目录。

| 项目 | 源位置 | 用户提供的占用 | SSD1 候选位置（切换前复核） |
| --- | --- | --- | --- |
| 模拟器设备数据 | `/Users/liguowei/Library/Developer/CoreSimulator/Devices` | 约 7.57 GiB | `/Volumes/SSD1/Xcode/CoreSimulator/Devices` |
| ImageAll 运行时 | `/Users/liguowei/Library/Containers/com.gwlee.ImageAll/Data/Library/Application Support/ImageAll/OpenMontageRuntime` | 约 7.35 GiB | `/Volumes/SSD1/ImageAll-AppData/OpenMontageRuntime` |

迁移保留全部设备、原 UDID、设备数据和可运行验收环境，不能转为删除设备或重新创建空设备。仅迁移指定运行时目录；Catalog、账号配置、钥匙串、任务目录与真实照片不属于迁移范围。

执行顺序：先完成正在进行的 USB 稳定性/冷恢复内存修复与原批次工作，保留现有断点和验证现场；原批次有明确结束状态及资源接收、封存、入库的分别核对记录后，再安排无传输、无验收、无渲染任务的维护窗口。未解决的不可访问项目必须保留和单列，不能据此误报全批完成。若需提前安排，须由负责原批次的聊天根据用户指示协调窗口，不因 App 暂时退出或设备 Shutdown 自行推定可以迁移。

本轮只做只读预检及文档记录，不复制约 15 GiB 数据以免争用现场 I/O，不启动或停止 App/服务，不操作 USB、不更改自动观察安排。

## 已核对的条件与未决项

- 当前 `main` 有大量混合已修改及未跟踪文件；保留 USB、OpenMontage 和其他在途工作，不覆盖、重置或整体提交。
- 本机 Xcode 26.6（17F113）；12 个模拟器均为 Shutdown 且 available。保留重点验收设备 `26C5316F-D642-409A-ADF3-6C0F135B9BE7`（ImageAll-USB-Click-Acceptance）。Xcode、CoreSimulator 服务仍运行。进程快照未见 ImageAll，**这不证明原 USB 批次完成或现场可释放**。
- SSD1 为可写 APFS，预检约 324 GiB 可用，`Owners: Disabled`。复制前需验证有效权限、ACL、扩展属性、可执行位及链接语义；不能把卷上显示的 uid/gid 当成权限完整性的充分证明，也不能擅自改变全卷所有权设置。
- 本机 `xcrun simctl help` 明确支持 `--set <path>`。这是 CLI 选择 device set 的依据，不能据此声称 Xcode 默认设备列表会自动使用外盘目录。尚未确认当前 Xcode GUI 的受支持持久配置方式；切换前需验证 Xcode 识别、目标选择与 Run 全链路。当前未选定符号链接或隐藏偏好项方案。
- Apple 官方站点的论坛搜索未提供足以确认当前 Xcode GUI 迁移支持的正式文档；历史外盘迁移失败讨论只作风险线索，不作为实施依据：[Apple Developer Forums](https://developer.apple.com/forums/thread/664398)。
- `ImageAll/App/OpenMontageIntegrationSettings.swift` 的启动器目前固定从 Application Support 的 `ImageAll/OpenMontageRuntime` 派生路径，随后将路径写入请求并交给 helper；`scripts/openmontage/Launcher.swift` 在该位置安装/校验/运行版本。App 启用 sandbox。实际切换需实现并验证持久的新运行时路径与访问授权，不能仅搬目录后假定能读，也不能把任务目录 bookmark 当成运行时的访问授权。相关源码已有其他改动，本轮不改。

## 实施及验收门禁

1. **冻结现场**：重新确认原批次状态、Xcode/模拟器/构建与运行时进程、打开文件、目标挂载与可用空间。记录源规范路径、卷 UUID、权限、版本、12 个设备清单；拒绝覆盖现有目标。无在途任务后再退出相关使用者；不强杀当前导入。
2. **可恢复复制**：在 SSD1 唯一 staging 目录复制，保留文件内容、可执行位、ACL、扩展属性、符号链接及必要硬链接关系。先审计链接，不能沿链接扩大到照片或其他未授权数据。源保留完整，任何失败都停在复制阶段。
3. **独立内容校验**：由独立于复制命令的校验器生成并比较源/目标相对路径、文件类型、大小、逐文件 SHA-256、链接目标和元数据；检查源在复制中未变化。零差异或每项已解释的系统元数据差异后才允许提升目标。清单私有保存在证据目录，不进入 Git，不输出账号/凭据内容。
4. **模拟器可运行验收**：先以 `simctl --set` 检查完整副本的设备/UDID/运行时对应关系；维护窗口中一次只启动一个设备。优先在原 USB 验收设备上完成合成 ImageAllMobile 安装、启动与最小交互，核实持久数据保留，再核实日常 Xcode 能发现、选择并 Run 到新位置。其余设备保留全部数据并验证可识别；不执行 erase/delete。GUI 路径支持未解决则源副本继续保留。
5. **OpenMontage 可运行验收**：记录路径选择方案/ADR，覆盖新路径、失效挂载和权限失败；SSD1 不可用时不得静默在系统盘重新安装大运行时。检查 Python/动态库/可执行文件是否含旧绝对路径。合成任务验证 helper 握手、版本/哈希校验、本地制作与结果恢复，不调用付费模型。再在当前 Xcode 项目的运行结果中验证持久配置确实指向 SSD1。如涉及 App 打包或手工替换，遵循 `docs/OPENMONTAGE-RELEASE.md`，不能用普通构建代替发布验收。
6. **切换与回滚**：切换前保存旧路径配置及可恢复源快照；以可撤销方式启用已验证目标。失败时停止新位置使用者、恢复旧配置与源目录，再验证原入口；防止新旧同时写入。模拟器启动后的新数据不得用旧备份盲目覆盖。
7. **源清理与证据**：两项分别通过内容、权限、运行及重启后路径复验，确认无进程引用旧位置后，才清理对应系统盘副本。清理前在 SSD1 保留独立、已校验的迁移前备份/归档，记录准确恢复命令及路径；限制清理到已授权且身份匹配的源目录，不清父目录。按实际文件系统空间统计释放量，不能把用户提供的约 14.92 GiB 当成已释放空间。

## 证据与后续接手

本轮证据：`/Volumes/SSD1/.codex-builds/StorageMigration-20261013/preflight-01/`，含 Git 状态、进程快照、源根目录元数据、simctl 帮助、设备清单、Xcode 版本、SSD1 信息和阶段状态。尚无内容哈希或运行验收结果。

后续执行须新建带时间戳证据目录，保存源/目标/恢复路径映射、校验结果、实际配置、运行证据和清理记录。计划完成的定义是两处均运行于 SSD1、原系统盘副本已按门禁清除且恢复材料齐全；当前仅完成预检与排期。

USB 上下文参见 `docs/ADR-104-USB-PHONE-IMPORT.md`；优先与“接手 ImageAll USB 导入”聊天协调，避免两个会话同时控制原批次。
