# Cursor 交接单：图库瘦身 S1（文件夹相同检测 · 只读）

> 状态：Ready  
> 日期：2026-07-27  
> 权威规格：[`LIBRARY-SLIMMING-SPEC.md`](LIBRARY-SLIMMING-SPEC.md) §7 S1；[`ADR-042-LIBRARY-SLIMMING-AND-RECYCLE.md`](ADR-042-LIBRARY-SLIMMING-AND-RECYCLE.md)  
> 上一批准基线：`main@8b8eba0a1efbe41b235938cb8b37c10708bc3163`（S0 文档）  
> 角色：临时授权期内可由本会话直接实施；交付 commit 使用实施身份与 `Agent-Role: implementation`

## 1. 范围

交付文件夹来源的**只读**相同检测：

1. 补全 `file_fingerprint.sha256`（既有列，今日恒为 NULL）；
2. 新增 `asset_similarity_fingerprint`（migration **v018**，规格文中的逻辑 V005 对应本仓库下一序号）；
3. 计算版本化感知指纹 `dhash-v1`（64-bit difference hash）；
4. 只读聚类 API：`byteIdentical` / `perceptualDuplicate`；
5. 合成 fixture 单元测试证明字节相同、转码近全等、明显不同三分组；
6. 证明不修改/移动/删除源文件。

## 2. 明确不做

- 侧栏 UI / 图库瘦身工作台（S2+）
- Feature Print / DINOv2 相似档（S2）
- 回收站、任何原图 rename/copy/delete（S4+）
- Photos 资产哈希补全或 PhotoKit 写入（S5）
- 改写 V001–V017；不触碰工作区既有未提交的 `LibraryWorkspace.swift` / `LibraryWorkspaceModelTests.swift`

## 3. 契约要点

| 项 | 值 |
|---|---|
| SHA-256 存储 | `file_fingerprint.sha256` raw 32-byte BLOB |
| 感知算法 | `dhash-v1`，8-byte BLOB |
| 近重复阈值 | Hamming ≤ 8（写入 `IdenticalDuplicatePolicy`，禁止散落魔法数） |
| 读取安全 | `FolderReconcileSourceAccessService` + `DerivedImageSourceReader`（no-follow FD） |
| 资格 | `locator_kind=file` ∧ `source.kind=folder` ∧ `current` ∧ `available` ∧ active source |
| 并发 | 写 sha256 时校验 size/mtime/resource_id 仍匹配，否则视为 sourceChanged 不写 |

## 4. 测试矩阵

1. 字节相同两文件 → 一簇 `byteIdentical`
2. 同像素 JPEG/PNG（或不同 JPEG 质量）→ `perceptualDuplicate`，且非 byteIdentical
3. 明显不同像素 → 不成簇
4. 完成后源文件 snapshot 不变
5. Fresh DB 含 v018；`knownOrdered` / schema expectations 更新
6. Photos locator 资产被跳过（不报错、不写）

## 5. 停止位置

S1 绿灯并本地提交后停止；不进入 S2 UI / 相似档。
