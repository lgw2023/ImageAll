import process from 'node:process';

import { startSandbox } from './dev-sandbox-runtime.mjs';

try {
  const sandbox = await startSandbox();
  process.stdout.write(
    `网页开发已启动：${sandbox.origin}/web-v2/gallery\n` +
      '请使用自动打开的独立 Chrome 窗口；合成数据只保存在该窗口内存中。\n' +
      '关闭该窗口或按 Ctrl+C 结束。日常 Mac App 无需退出。\n',
  );
  let stopping = false;
  const stop = async () => {
    if (stopping) return;
    stopping = true;
    await sandbox.close();
  };
  process.once('SIGINT', () => void stop());
  process.once('SIGTERM', () => void stop());
  sandbox.page.once('close', () => void stop());
  sandbox.browser.once('disconnected', () => void stop());
} catch (error) {
  process.stderr.write(`网页开发启动失败：${error.message}\n`);
  process.exitCode = 1;
}
