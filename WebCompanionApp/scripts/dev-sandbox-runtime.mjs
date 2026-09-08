/* global document */
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { chromium } from '@playwright/test';
import { createServer } from 'vite';

const appRoot = fileURLToPath(new URL('../', import.meta.url));

export function requireDevelopmentWorktree() {
  const git = (...args) => execFileSync('git', args, { cwd: appRoot, encoding: 'utf8' }).trim();
  const branch = git('branch', '--show-current');
  const gitDirectory = git('rev-parse', '--absolute-git-dir');
  const commonDirectory = git('rev-parse', '--path-format=absolute', '--git-common-dir');
  if (!branch || branch === 'main' || branch === 'master' || gitDirectory === commonDirectory) {
    throw new Error('请在独立的网页开发 worktree / 开发分支运行，不能从主工作目录启动。');
  }
}

export async function startSandbox({ headless = false, port = 5173 } = {}) {
  requireDevelopmentWorktree();
  let server;
  let browser;
  let closing;
  const close = () => {
    closing ??= (async () => {
      try {
        await browser?.close();
      } finally {
        await server?.close();
      }
    })();
    return closing;
  };

  try {
    server = await createServer({
      root: appRoot,
      server: { host: '127.0.0.1', port, strictPort: true, open: false },
      plugins: [
        {
          name: 'imageall-synthetic-only-server',
          configureServer(devServer) {
            devServer.middlewares.use((request, response, next) => {
              const pathname = new URL(request.url ?? '/', 'http://localhost').pathname;
              if (/^\/(v1|web|world-map)(\/|$)/.test(pathname)) {
                response.statusCode = 503;
                response.setHeader('Content-Type', 'application/json');
                response.end(JSON.stringify({ error: 'synthetic_browser_required' }));
                return;
              }
              next();
            });
          },
        },
      ],
    });
    await server.listen();
    const origin = `http://127.0.0.1:${port}`;
    const { installSyntheticAuthenticatedHost } = await server.ssrLoadModule(
      '/tests/e2e/syntheticHost.ts',
    );
    browser = await chromium.launch({ channel: 'chrome', headless });
    const context = await browser.newContext({
      viewport: { width: 1440, height: 960 },
      serviceWorkers: 'block',
      acceptDownloads: false,
    });
    // Unknown API requests never fall through to a real Host. No API proxy exists.
    await context.route('**/*', (route) => {
      const url = new URL(route.request().url());
      if (url.origin !== origin) return route.abort('blockedbyclient');
      if (/^\/(v1|web|world-map)(\/|$)/.test(url.pathname)) {
        return route.fulfill({
          status: 501,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'unimplemented_synthetic_endpoint' }),
        });
      }
      return route.continue();
    });
    await context.routeWebSocket('**/*', (socket) => {
      const url = new URL(socket.url());
      if (url.origin === origin.replace('http:', 'ws:') && url.pathname === '/web-v2/') {
        socket.connectToServer(); // Vite hot reload only.
      } else {
        void socket.close({ code: 1008, reason: 'Sandbox blocks non-development sockets' });
      }
    });
    const page = await context.newPage();
    const consoleMessages = [];
    page.on('console', (message) => consoleMessages.push(message.text()));
    await installSyntheticAuthenticatedHost(page);
    // Page routes precede context routes; check the origin before fixture matching.
    await page.route('**/*', (route) =>
      new URL(route.request().url()).origin === origin
        ? route.fallback()
        : route.abort('blockedbyclient'),
    );
    context.on('page', (extraPage) => {
      if (extraPage !== page) void extraPage.close();
    });
    await page.addInitScript(() => {
      document.addEventListener('DOMContentLoaded', () => {
        const badge = document.createElement('div');
        badge.id = 'imageall-development-badge';
        badge.textContent = '网页开发 · 合成数据 · 不连接日常 App';
        badge.style.cssText =
          'position:fixed;bottom:6px;left:6px;z-index:2147483647;padding:5px 10px;' +
          'background:#153b32;color:white;border-radius:6px;font:12px system-ui;pointer-events:none';
        document.body.append(badge);
      });
    });
    await page.goto(`${origin}/web-v2/gallery`);
    return { browser, context, page, server, origin, close, consoleMessages };
  } catch (error) {
    await close();
    throw error;
  }
}
