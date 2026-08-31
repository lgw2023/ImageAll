import { installMediaAuthorizationResponder, readAccountAuthorization } from '@/api/credentials';

export function registerServiceWorker(): () => void {
  if (!import.meta.env.PROD || !('serviceWorker' in navigator)) return () => undefined;
  const removeResponder = installMediaAuthorizationResponder();
  void navigator.serviceWorker
    .register('/web-v2/service-worker.js', { scope: '/', updateViaCache: 'none' })
    .then(async (registration) => {
      await registration.update();
      const worker = registration.active ?? registration.waiting ?? registration.installing;
      worker?.postMessage({
        type: 'imageall-media-authorization',
        authorization: readAccountAuthorization(),
      });
    })
    .catch(() => undefined);
  return removeResponder;
}
