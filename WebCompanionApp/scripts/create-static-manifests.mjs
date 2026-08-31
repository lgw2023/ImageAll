import { createHash } from 'node:crypto';
import { readdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, extname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const outputDirectory = resolve(scriptDirectory, '../../ImageAll/Resources/WebCompanionV2');

const mimeTypes = new Map([
  ['.css', 'text/css; charset=utf-8'],
  ['.html', 'text/html; charset=utf-8'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.map', 'application/json; charset=utf-8'],
  ['.png', 'image/png'],
  ['.svg', 'image/svg+xml'],
  ['.webmanifest', 'application/manifest+json; charset=utf-8'],
  ['.woff2', 'font/woff2'],
]);

const spaRoutes = [
  '',
  'gallery',
  'gallery/favorites',
  'gallery/overview',
  'assets/:assetId',
  'review',
  'review/queue',
  'map',
  'training',
  'slimming',
  'sources',
  'storage',
  'tags',
  'activity',
  'settings',
];

async function walk(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const paths = [];
  for (const entry of entries) {
    const child = join(directory, entry.name);
    if (entry.isDirectory()) paths.push(...(await walk(child)));
    if (entry.isFile()) paths.push(child);
  }
  return paths;
}

const generatedNames = new Set(['asset-manifest.json', 'offline-assets.json']);
const files = (await walk(outputDirectory))
  .filter((path) => {
    const outputPath = relative(outputDirectory, path).split('\\').join('/');
    return !generatedNames.has(outputPath) && outputPath !== '.vite/manifest.json';
  })
  .sort((left, right) => left.localeCompare(right));

const serviceWorkerPath = join(outputDirectory, 'service-worker.js');
const shellVersionHash = createHash('sha256');
for (const file of files) {
  if (file === serviceWorkerPath) continue;
  shellVersionHash.update(relative(outputDirectory, file));
  shellVersionHash.update(await readFile(file));
}
const shellVersion = shellVersionHash.digest('hex').slice(0, 16);
const serviceWorkerSource = await readFile(serviceWorkerPath, 'utf8');
if (!serviceWorkerSource.includes('__IMAGEALL_SHELL_VERSION__')) {
  throw new Error('Service worker shell version placeholder missing');
}
await writeFile(
  serviceWorkerPath,
  serviceWorkerSource.replaceAll('__IMAGEALL_SHELL_VERSION__', shellVersion),
);

const assets = [];
for (const file of files) {
  const path = relative(outputDirectory, file).split('\\').join('/');
  const extension = extname(path);
  const mimeType = mimeTypes.get(extension);
  if (!mimeType) throw new Error(`No audited MIME type for ${path}`);
  const data = await readFile(file);
  assets.push({
    path,
    mimeType,
    sha256: createHash('sha256').update(data).digest('hex'),
    cachePolicy: /^assets\/.+-[A-Za-z0-9_-]{8,}\./.test(path) ? 'immutable' : 'no-store',
  });
}

const offlineAssets = assets
  .filter(
    ({ path }) =>
      path === 'index.html' ||
      path === 'manifest.webmanifest' ||
      path === 'icon.svg' ||
      path.startsWith('assets/'),
  )
  .map(({ path }) => `/web-v2/${path}`);

await writeFile(
  join(outputDirectory, 'offline-assets.json'),
  `${JSON.stringify({ version: 1, assets: offlineAssets }, null, 2)}\n`,
);

const offlineManifestData = await readFile(join(outputDirectory, 'offline-assets.json'));
assets.push({
  path: 'offline-assets.json',
  mimeType: 'application/json; charset=utf-8',
  sha256: createHash('sha256').update(offlineManifestData).digest('hex'),
  cachePolicy: 'no-store',
});
assets.sort((left, right) => left.path.localeCompare(right.path));

await writeFile(
  join(outputDirectory, 'asset-manifest.json'),
  `${JSON.stringify({ version: 1, basePath: '/web-v2/', entrypoint: 'index.html', spaRoutes, assets }, null, 2)}\n`,
);
