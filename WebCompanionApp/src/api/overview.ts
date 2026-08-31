import { requestJSON } from './client';
import { galleryOverviewSchema } from './contracts/overview';

export function fetchGalleryOverview(signal?: AbortSignal) {
  return requestJSON('/v1/gallery-overview', galleryOverviewSchema, { signal: signal ?? null });
}
