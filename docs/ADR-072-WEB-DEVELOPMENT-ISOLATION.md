# ADR-072：网页开发与日常 Mac App 隔离

日期：2026-09-08。状态：已决定；本轮交付前端合成数据开发环境。

## 需求与现状

用户需要持续开发网页版，同时照常使用 Mac App。主仓库保留 `main`，从当前
`3ee5f05c` 创建 `lgw/imageall-web-dev` 和独立 worktree `ImageAll-Web-Dev`。

目前网页 API 使用同源地址；Vite 没有后端代理，构建会更新当前 checkout 内的
`ImageAll/Resources/WebCompanionV2`。Mac Host 共享应用数据路径，且本地网页端口固定
为 8788。因此，仅复制 App 或创建分支不足以支持两个真实 Host 的安全并行运行。

## 本轮决策

- 日常 App 保留经签名校验的独立二进制副本；不由网页开发命令构建、覆盖或启动。
- 前端开发入口为 `WebCompanionApp` 下的 `npm run dev`：启动仅监听 127.0.0.1:5173
  的 Vite，打开独立、临时 Chrome 上下文，复用现有 Playwright synthetic Host。
- 在独立窗口中交互、刷新和热更新；图像和业务响应均来自测试 fixture。状态只在本次
  窗口会话内存中，退出后丢弃。页面明确显示合成数据标记。
- 默认阻断未知 API 和其他网络来源，不提供指向日常 Host 的代理或回退。
  禁用 Service Worker，避免沿用日常账号、缓存、配对信息和浏览器配置。
- 普通浏览器直接访问开发 URL 不带 fixture，API 返回 503；必须使用自动打开的窗口。
- 端口被占用时直接报错；关闭窗口或 Ctrl+C 只关闭本命令创建的浏览器与服务。
- 原有 `npm run build` 仍输出到本 worktree 的 App 资源目录，不更改生产构建契约。
  不共享 node_modules，也不运行主目录里的 Xcode 构建或 App 重启脚本。

## 验收与边界

主路径：启动独立窗口 → 展示合成图库 → 收藏修改 → 刷新仍保留本会话状态 → 打开预览。
失败路径：未知 API 返回明确失败；请求独立测试探针被阻断，探针收到零次请求。
保留已有 typecheck、单元测试、构建及相关浏览器回归。主仓库 HEAD 和文件状态不变。

这不是完整真实 Mac Host 联调环境。认证、PhotoKit、真实训练、真实地图以及 fixture
未覆盖的接口，不能据此宣称已通过真实环境验收。若需修改 Swift API，先实现并验证独立
应用身份、数据库/缓存/设置/钥匙串、测试来源、8787/8788 替代端口和 DerivedData 的隔离，
再启动开发 Host。不得以仅设置 HOME 或改 App 文件名代替这些隔离。

稳定切片验证通过后再按用户决定合入 main、发布新的日常 App；工作分支仅本地提交。

## 本轮验证记录

- `npm run test:dev-sandbox`：合成图库交互、收藏状态、刷新与预览、未知 API 拒绝、
  外部 HTTP 探针零请求、普通浏览器 API 拒绝、Vite 连接与更新刷新、端口占用拒绝。
- `npm run typecheck`、`npm run lint`、`npm run test:run`（35 tests）通过。
- `npm run build` 通过；重新生成的生产网页资源无 Git 差异。
- Chromium desktop 图库主路径 E2E 通过（浏览、多选、修改、撤销、详情、无障碍检查）。
- `/Volumes/SSD1/ImageAll-Daily/ImageAll.app` 与既有 Debug App 普通文件 SHA-256 清单一致，
  `codesign --verify --deep --strict` 通过。本次未运行真实 App，也未访问真实图库。
- 主仓库保持 `3ee5f05c` / main 且干净；构建与测试均在新 worktree 进行。
