# 独立网页开发

在 `/Volumes/SSD1/ImageAll-Web-Dev` 的 `lgw/imageall-web-dev` 分支工作。
`/Volumes/SSD1/ImageAll` 保持 main，用于稳定集成。
日常 App 的固定副本位于 `/Volumes/SSD1/ImageAll-Daily/ImageAll.app`；复制完整性和签名
已核验，未自动启动。它保留原有日常数据身份，不能当作第二个隔离测试 Host 启动。

```sh
cd /Volumes/SSD1/ImageAll-Web-Dev/WebCompanionApp
npm ci
npm run dev
```

需要 Node >=22.12 和已安装的 Google Chrome。命令自动打开独立 Chrome 窗口，
地址为 `http://127.0.0.1:5173/web-v2/gallery`。请在这个窗口操作，编辑 `src/`
后由 Vite 热更新；不需要退出或重启日常 Mac App。关闭窗口或 Ctrl+C 停止开发环境。

使用合成照片和模拟 Host；收藏、标签等支持的操作仅影响本窗口内存，重启开发环境重置。
未覆盖的接口明确失败，不回退到真实 Host。普通浏览器直接打开 URL 不提供模拟接口。
当前主要用于已登录状态的前端交互；登录/退出等流程继续使用对应 E2E 测试。

```sh
npm run test:dev-sandbox
npm run typecheck
npm run test:run
npm run build
npm run test:e2e -- --project=chromium-desktop --workers=1
```

独立入口 smoke 使用 5174；现有构建 E2E 使用 4173。所有端口都必须空闲，不结束占用者。
构建产物在本 worktree 的 `ImageAll/Resources/WebCompanionV2`，不会复制进日常 App。

当前入口不启动 Swift Host。真实后端联调的隔离要求见
[ADR-072](../docs/ADR-072-WEB-DEVELOPMENT-ISOLATION.md)。不要将 dev server 代理到日常
8787/8788，不要运行会覆盖共享 DerivedData 或重启日常 App 的脚本。
