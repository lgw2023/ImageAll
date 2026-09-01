'use strict';

const CACHE_PREFIX = 'imageall-web-v2-shell-';
const CACHE_NAME = `${CACHE_PREFIX}d758c14e1c951784`;
let accountAuthorization = null;

function requestAuthorizationFromSpecificClient(client) {
  return new Promise((resolve) => {
    const channel = new MessageChannel();
    const timeout = setTimeout(() => resolve(null), 1000);
    channel.port1.onmessage = (event) => {
      clearTimeout(timeout);
      const authorization = event.data?.authorization;
      resolve(
        typeof authorization === 'string' && authorization.startsWith('Basic ')
          ? authorization
          : null,
      );
    };
    client.postMessage({ type: 'imageall-media-authorization-request' }, [channel.port2]);
  });
}

async function requestAuthorizationFromClient(clientId) {
  const candidates = [];
  if (clientId) {
    const client = await self.clients.get(clientId);
    if (client) candidates.push(client);
  }
  const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: false });
  for (const client of windows) {
    if (!candidates.some((candidate) => candidate.id === client.id)) candidates.push(client);
  }
  for (const client of candidates) {
    const authorization = await requestAuthorizationFromSpecificClient(client);
    if (authorization) return authorization;
  }
  return null;
}

async function precachePublicShell() {
  const response = await fetch('/web-v2/offline-assets.json', {
    cache: 'no-store',
    credentials: 'same-origin',
  });
  if (!response.ok) throw new Error('offline asset manifest unavailable');
  const manifest = await response.json();
  if (manifest?.version !== 1 || !Array.isArray(manifest.assets)) {
    throw new Error('offline asset manifest malformed');
  }
  const urls = manifest.assets.filter(
    (value) => typeof value === 'string' && value.startsWith('/web-v2/') && !value.includes('..'),
  );
  const responses = await Promise.all(
    urls.map(async (url) => {
      const asset = await fetch(url, {
        cache: 'reload',
        credentials: 'same-origin',
      });
      if (!asset.ok) throw new Error(`public shell asset unavailable: ${url}`);
      const headers = new Headers(asset.headers);
      headers.delete('connection');
      headers.delete('content-encoding');
      headers.delete('content-length');
      headers.delete('keep-alive');
      headers.delete('transfer-encoding');
      headers.delete('vary');
      const normalized = new Response(await asset.arrayBuffer(), {
        status: asset.status,
        statusText: asset.statusText,
        headers,
      });
      return [url, normalized];
    }),
  );
  const cache = await caches.open(CACHE_NAME);
  await Promise.all(responses.map(([url, response]) => cache.put(url, response)));
}

self.addEventListener('install', (event) => {
  event.waitUntil(precachePublicShell().then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(
        keys
          .filter((key) => key.startsWith(CACHE_PREFIX) && key !== CACHE_NAME)
          .map((key) => caches.delete(key)),
      );
      await self.clients.claim();
    })(),
  );
});

self.addEventListener('message', (event) => {
  if (event.data?.type !== 'imageall-media-authorization') return;
  const authorization = event.data.authorization;
  accountAuthorization =
    typeof authorization === 'string' && authorization.startsWith('Basic ') ? authorization : null;
  event.ports[0]?.postMessage({ ready: true });
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;

  const isProtectedAssetRequest =
    /^\/v1\/assets\/[0-9a-f-]+\/(?:thumbnail|preview|media)$/i.test(url.pathname) &&
    ['GET', 'HEAD'].includes(event.request.method);
  if (isProtectedAssetRequest) {
    event.respondWith(
      (async () => {
        const authorization =
          accountAuthorization || (await requestAuthorizationFromClient(event.clientId));
        if (!authorization) return fetch(event.request);
        const headers = new Headers(event.request.headers);
        headers.set('Authorization', authorization);
        return fetch(
          new Request(event.request.url, {
            method: event.request.method,
            headers,
            mode: 'same-origin',
            credentials: 'same-origin',
            cache: 'no-store',
            redirect: 'follow',
          }),
        );
      })(),
    );
    return;
  }

  const isPublicV2ShellRequest =
    event.request.method === 'GET' &&
    url.pathname.startsWith('/web-v2/') &&
    !url.pathname.startsWith('/web-v2/asset-manifest.json') &&
    !url.pathname.startsWith('/web-v2/offline-assets.json');
  if (!isPublicV2ShellRequest) return;

  event.respondWith(
    (async () => {
      try {
        return await fetch(event.request);
      } catch {
        const cache = await caches.open(CACHE_NAME);
        const exact = await cache.match(event.request, { ignoreSearch: true, ignoreVary: true });
        if (exact) return exact;
        const acceptsHTML = event.request.headers.get('accept')?.includes('text/html');
        if (acceptsHTML) {
          const shell = await cache.match('/web-v2/index.html');
          if (shell) return shell;
        }
        throw new Error('public shell resource unavailable offline');
      }
    })(),
  );
});
