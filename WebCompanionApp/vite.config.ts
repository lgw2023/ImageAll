import { fileURLToPath, URL } from 'node:url';

import react from '@vitejs/plugin-react';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  base: '/web-v2/',
  plugins: [
    react(),
    {
      name: 'imageall-trim-output-trailing-whitespace',
      renderChunk(code) {
        return { code: code.replace(/[\t ]+$/gm, ''), map: null };
      },
    },
  ],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  build: {
    outDir: '../ImageAll/Resources/WebCompanionV2',
    emptyOutDir: true,
    sourcemap: false,
  },
  server: {
    port: 5173,
    strictPort: true,
  },
  preview: {
    headers: {
      'Service-Worker-Allowed': '/',
    },
  },
  test: {
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    exclude: ['tests/e2e/**', 'node_modules/**'],
    restoreMocks: true,
    clearMocks: true,
    css: true,
  },
});
