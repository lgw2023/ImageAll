import { z } from 'zod';

import { requestJSON } from './client';
import {
  locationBackfillResponseSchema,
  locationBackfillSchema,
  worldMapPlaceResponseSchema,
  worldMapPlaceSnapshotSchema,
  worldMapSelectionSchema,
  worldMapSnapshotSchema,
  type WorldMapBounds,
  type WorldMapSelectionQuery,
} from './contracts/map';

export function fetchWorldMap(bounds: WorldMapBounds | null, signal?: AbortSignal) {
  const parameters = new URLSearchParams({ maximumClusters: '2000' });
  if (bounds) {
    for (const [key, value] of Object.entries(bounds)) parameters.set(key, String(value));
  }
  return requestJSON(`/v1/world-map/snapshot?${parameters.toString()}`, worldMapSnapshotSchema, {
    signal: signal ?? null,
  });
}

export function fetchWorldMapSelection(query: WorldMapSelectionQuery, signal?: AbortSignal) {
  return requestJSON('/v1/world-map/selection', worldMapSelectionSchema, {
    method: 'POST',
    body: JSON.stringify({ query }),
    signal: signal ?? null,
  });
}

export function fetchLocationBackfills(signal?: AbortSignal) {
  return requestJSON('/v1/world-map/location-backfill', z.array(locationBackfillSchema), {
    signal: signal ?? null,
  });
}

export function applyLocationBackfill(sourceID: string, action: 'start' | 'cancel') {
  return requestJSON('/v1/world-map/location-backfill/requests', locationBackfillResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), sourceID, action }),
  });
}

export function fetchWorldMapPlaces(signal?: AbortSignal) {
  return requestJSON('/v1/world-map/place-tags', worldMapPlaceSnapshotSchema, {
    signal: signal ?? null,
  });
}

export function searchWorldMapPlace(tagID: string, query: string) {
  return requestJSON('/v1/world-map/place-tags/requests', worldMapPlaceResponseSchema, {
    method: 'POST',
    body: JSON.stringify({
      operationID: crypto.randomUUID(),
      tagID,
      action: 'search',
      query,
    }),
  });
}

export function confirmWorldMapPlace(tagID: string, placeID: string) {
  return requestJSON('/v1/world-map/place-tags/requests', worldMapPlaceResponseSchema, {
    method: 'POST',
    body: JSON.stringify({
      operationID: crypto.randomUUID(),
      tagID,
      action: 'confirm',
      placeID,
    }),
  });
}
