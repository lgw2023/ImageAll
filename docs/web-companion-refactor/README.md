# Web Companion 系统性重构

本目录是 Web Companion 从原生 HTML/CSS/JavaScript 单体向 Vite + React + TypeScript
工程化应用迁移的可审计交付面。它不是一份一次性计划：功能矩阵、验收门、测试证据和截图必须
随每个纵切片一起更新。

> 2026-08-31：新版已处于 `default`，根入口跳转至 `/web-v2/gallery`；旧版按 ADR-064 明确保留在
> `/legacy/` 至少一个稳定发布周期。工程自动化门已完成，人工 VoiceOver 与真实发布环境
> MapLibre/Host 验收仍作为发布检查单列，不得用合成证据外推。

## 决策边界

- [ADR-063](../ADR-063-WEB-COMPANION-REACT-ARCHITECTURE.md)：新应用技术架构、交付形式和非功能门。
- [ADR-064](../ADR-064-WEB-COMPANION-INCREMENTAL-MIGRATION.md)：旁路运行、逐流程迁移、默认切换与旧版退场。
- 本轮不改动 PhotoKit/GRDB 权威语义，不重写远程业务协议，不将私有图像或 API 结果加入
  Service Worker 缓存。
- 只允许用合成 fixture 做自动化验证。本阶段不读取、遍历或写入 HDD2 上的受保护真实数据。

## 文档索引

- [PHASE-0-AUDIT.md](PHASE-0-AUDIT.md)：当前实现、资源链、安全边界、技术债和基线证据。
- [FEATURE-PARITY-MATRIX.md](FEATURE-PARITY-MATRIX.md)：Mac、旧 Web、新 Web 的功能对照和迁移状态。
- [API-INVENTORY.md](API-INVENTORY.md)：现有 Host API、类型源和缺失能力。
- [DESIGN-SYSTEM.md](DESIGN-SYSTEM.md)：视觉语汇、令牌、断点、可访问性和动效。
- [INFORMATION-ARCHITECTURE.md](INFORMATION-ARCHITECTURE.md)：信息架构和路由。
- [COMPONENT-MAP.md](COMPONENT-MAP.md)：页面、功能模块与通用组件边界。
- [ROUTING-STATE-MODEL.md](ROUTING-STATE-MODEL.md)：URL、历史、服务端、工作区和局部状态的归属。
- [API-TYPE-MODEL.md](API-TYPE-MODEL.md)：协议 schema、解码、错误和事件一致性。
- [TEST-STRATEGY.md](TEST-STRATEGY.md)：分层测试、fixture、视觉/性能/可访问性和 Swift 包装验证。
- [ACCEPTANCE-GATES.md](ACCEPTANCE-GATES.md)：切换默认入口和删除旧实现前的硬门。
- [DELIVERY-2026-08-31.md](DELIVERY-2026-08-31.md)：本轮中文交付、验证结果、限制、提交与回滚。
- [PROGRESS-2026-09-01-CLOUD-AND-SUGGESTIONS.md](PROGRESS-2026-09-01-CLOUD-AND-SUGGESTIONS.md)：持续功能对齐中的 iCloud 单图恢复、待审建议与下一批细粒度缺口。
- [PROGRESS-2026-09-01-NOCTURNE-AND-GALLERY-WORKFLOWS.md](PROGRESS-2026-09-01-NOCTURNE-AND-GALLERY-WORKFLOWS.md)：即时模型、收藏重试、原子标签闭环，以及脱离 Mac 外观的 Nocturne Web 视觉重构。
- [PROGRESS-2026-09-01-REVIEW-CONTINUOUS-WORKFLOW.md](PROGRESS-2026-09-01-REVIEW-CONTINUOUS-WORKFLOW.md)：以 Mac 审核工作区为权威重新审计 Review，并交付 Space/P/X/U 连续单图审核闭环。
- [PROGRESS-2026-09-01-REVIEW-SOURCE-SCOPE.md](PROGRESS-2026-09-01-REVIEW-SOURCE-SCOPE.md)：交付 Review 全部/部分/零来源的 URL、Host、总览与队列一致性闭环。
- [PROGRESS-2026-09-01-REVIEW-VIEW-CONTEXT.md](PROGRESS-2026-09-01-REVIEW-VIEW-CONTEXT.md)：交付 Review 9 档密度、缓存优先原比例和 URL/当前项连续性。
- [PROGRESS-2026-09-01-REVIEW-CLOUD-PREVIEW.md](PROGRESS-2026-09-01-REVIEW-CLOUD-PREVIEW.md)：交付 Review 单图显式 iCloud 获取、权威进度、取消/重试与原位恢复。
- [PROGRESS-2026-09-01-REVIEW-SUGGESTION-LIMIT.md](PROGRESS-2026-09-01-REVIEW-SUGGESTION-LIMIT.md)：交付 Review 概览共享每标签上限、Host 失败调和与跨队列连续性。
- [PROGRESS-2026-09-01-REVIEW-MODEL-CONTROL.md](PROGRESS-2026-09-01-REVIEW-MODEL-CONTROL.md)：交付 Review 本地模型服务状态、标准/个人双轨生成与任务控制。
- [PROGRESS-2026-09-01-PRISM-REDESIGN.md](PROGRESS-2026-09-01-PRISM-REDESIGN.md)：基于行业调研重构独立的 Prism Web 视觉系统、图库画布与 Review AI 工作台。
- [PROGRESS-2026-09-01-SOURCE-MANAGEMENT-COMMAND-DECK.md](PROGRESS-2026-09-01-SOURCE-MANAGEMENT-COMMAND-DECK.md)：以独立的暗房控制台视觉交付完整来源管理、状态门控、任务取消与安全移除闭环。
- [PROGRESS-2026-09-01-HELIOS-WEB-REDESIGN.md](PROGRESS-2026-09-01-HELIOS-WEB-REDESIGN.md)：在功能对齐、视觉独立的边界下，交付 Helios 全站视觉系统、移动筛选抽屉与完整存储命令工作台。

## 状态词汇

| 状态 | 含义 |
| --- | --- |
| `baseline` | 只完成旧版盘点和证据冻结 |
| `foundation` | 已建立新工程基座，但功能不算迁移 |
| `in-progress` | 新纵切片可运行，尚未通过全部门 |
| `parity-proven` | 主路径、必要失败路径、回归与截图证据均完整 |
| `default` | 新版已是默认入口，旧版仍可回滚 |
| `retired` | 稳定周期结束且退场清单完成，旧实现已删除 |
