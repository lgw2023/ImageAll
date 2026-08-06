"use strict";

let accountAuthorization = null;

function requestAuthorizationFromSpecificClient(client) {
  return new Promise((resolve) => {
    const channel = new MessageChannel();
    const timeout = setTimeout(() => resolve(null), 1000);
    channel.port1.onmessage = (event) => {
      clearTimeout(timeout);
      const authorization = event.data?.authorization;
      resolve(typeof authorization === "string"
        && authorization.startsWith("Basic ")
        ? authorization
        : null);
    };
    client.postMessage({
      type: "imageall-media-authorization-request",
    }, [channel.port2]);
  });
}

async function requestAuthorizationFromClient(clientId) {
  const candidates = [];
  if (clientId) {
    const initiatingClient = await self.clients.get(clientId);
    if (initiatingClient) candidates.push(initiatingClient);
  }

  // Chromium may omit FetchEvent.clientId for a native <video> range request.
  // Fall back to controlled same-origin windows so a restarted worker can
  // recover the transient Basic value from page memory without persisting it.
  const windows = await self.clients.matchAll({
    type: "window",
    includeUncontrolled: false,
  });
  for (const client of windows) {
    if (!candidates.some((candidate) => candidate.id === client.id)) {
      candidates.push(client);
    }
  }

  for (const client of candidates) {
    const authorization = await requestAuthorizationFromSpecificClient(client);
    if (authorization) return authorization;
  }
  return null;
}

self.addEventListener("install", (event) => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("message", (event) => {
  if (event.data?.type !== "imageall-media-authorization") return;
  const authorization = event.data.authorization;
  accountAuthorization = typeof authorization === "string"
    && authorization.startsWith("Basic ")
    ? authorization
    : null;
  event.ports[0]?.postMessage({ ready: true });
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  const isMediaRequest = url.origin === self.location.origin
    && /^\/v1\/assets\/[0-9a-f-]+\/media$/i.test(url.pathname)
    && ["GET", "HEAD"].includes(event.request.method);
  if (!isMediaRequest) return;

  event.respondWith((async () => {
    // Service workers may be terminated between events. Recover the transient
    // Basic value from the initiating page's memory instead of persisting it.
    const authorization = accountAuthorization
      || await requestAuthorizationFromClient(event.clientId);
    if (!authorization) return fetch(event.request);

    const headers = new Headers(event.request.headers);
    headers.set("Authorization", authorization);
    // Native <video> requests can arrive with mode=no-cors. Reusing that
    // Request would strip the non-safelisted Authorization header even for
    // this same-origin fetch, so rebuild a same-origin GET/HEAD explicitly.
    return fetch(new Request(event.request.url, {
      method: event.request.method,
      headers,
      mode: "same-origin",
      credentials: "same-origin",
      cache: "no-store",
      redirect: "follow",
    }));
  })());
});
