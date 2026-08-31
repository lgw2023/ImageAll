let accountAuthorization: string | null = null;

export function readAccountAuthorization(): string | null {
  return accountAuthorization;
}

export function setAccountAuthorization(value: string | null): void {
  accountAuthorization = value;
  void updateMediaWorkerAuthorization(value);
}

export function makeBasicAuthorization(username: string, password: string): string {
  const bytes = new TextEncoder().encode(`${username}:${password}`);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return `Basic ${btoa(binary)}`;
}

async function updateMediaWorkerAuthorization(authorization: string | null): Promise<boolean> {
  if (!('serviceWorker' in navigator)) return false;
  const worker = navigator.serviceWorker.controller;
  if (!worker) return false;
  return new Promise((resolve) => {
    const channel = new MessageChannel();
    const timeout = window.setTimeout(() => resolve(false), 2000);
    channel.port1.onmessage = () => {
      window.clearTimeout(timeout);
      resolve(true);
    };
    worker.postMessage({ type: 'imageall-media-authorization', authorization }, [channel.port2]);
  });
}

export function installMediaAuthorizationResponder(): () => void {
  if (!('serviceWorker' in navigator)) return () => undefined;
  const handler = (event: MessageEvent<unknown>) => {
    const data = event.data as { type?: unknown } | null;
    if (data?.type !== 'imageall-media-authorization-request') return;
    event.ports[0]?.postMessage({ authorization: accountAuthorization });
  };
  navigator.serviceWorker.addEventListener('message', handler);
  return () => navigator.serviceWorker.removeEventListener('message', handler);
}
