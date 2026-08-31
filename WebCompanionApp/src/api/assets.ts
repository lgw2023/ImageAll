import { requestEmpty, requestJSON } from './client';
import {
  assetDetailSchema,
  assetPageSchema,
  favoriteMutationResponseSchema,
  type AssetMediaKind,
  type AssetPage,
  type AssetSort,
  type AssetSummary,
  type FavoriteMutationResponse,
} from './contracts/asset';
import type { WorldMapSelectionQuery } from './contracts/map';

export type AssetQuery = {
  searchText: string;
  sort: AssetSort;
  mediaKind: AssetMediaKind | null;
  acceptedTagID: string | null;
  favoritesOnly: boolean;
  worldMapSelection: WorldMapSelectionQuery | null;
};

export async function fetchAssetPage(
  query: AssetQuery,
  cursor: string | null,
  signal?: AbortSignal,
): Promise<AssetPage> {
  const parameters = new URLSearchParams({ sort: query.sort, limit: '72' });
  const searchText = query.searchText.trim();
  if (searchText) parameters.set('q', searchText);
  if (query.mediaKind) parameters.set('mediaKinds', query.mediaKind);
  if (query.acceptedTagID) parameters.set('acceptedTagIDs', query.acceptedTagID);
  if (query.favoritesOnly) parameters.set('favorite', 'favorited');
  if (query.worldMapSelection) {
    parameters.set('worldMapCellDegrees', String(query.worldMapSelection.cellDegrees));
    parameters.set('worldMapLongitudeBucket', String(query.worldMapSelection.longitudeBucket));
    parameters.set('worldMapLatitudeBucket', String(query.worldMapSelection.latitudeBucket));
    parameters.set('worldMapMaximumAssets', String(query.worldMapSelection.maximumAssets));
    if (query.worldMapSelection.bounds) {
      parameters.set('worldMapWest', String(query.worldMapSelection.bounds.west));
      parameters.set('worldMapSouth', String(query.worldMapSelection.bounds.south));
      parameters.set('worldMapEast', String(query.worldMapSelection.bounds.east));
      parameters.set('worldMapNorth', String(query.worldMapSelection.bounds.north));
    }
  }
  if (cursor) parameters.set('cursor', cursor);
  return requestJSON(`/v1/assets?${parameters.toString()}`, assetPageSchema, {
    signal: signal ?? null,
  });
}

export async function fetchAssetDetail(assetID: string, signal?: AbortSignal) {
  return requestJSON(`/v1/assets/${encodeURIComponent(assetID)}`, assetDetailSchema, {
    signal: signal ?? null,
  });
}

export async function mutateFavorites(
  assetIDs: string[],
  isFavorite: boolean,
): Promise<FavoriteMutationResponse> {
  return requestJSON('/v1/favorites', favoriteMutationResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), assetIDs, isFavorite }),
  });
}

export async function openOriginalAsset(assetID: string): Promise<void> {
  return requestEmpty(`/v1/assets/${encodeURIComponent(assetID)}/open-original`, {
    method: 'POST',
    body: '{}',
  });
}

export function assetThumbnailURL(asset: AssetSummary, width = 420): string {
  const parameters = new URLSearchParams({
    w: String(width),
    revision: String(asset.contentRevision),
  });
  return `/v1/assets/${encodeURIComponent(asset.id)}/thumbnail?${parameters.toString()}`;
}

export function assetPreviewURL(assetID: string, contentRevision: number): string {
  return `/v1/assets/${encodeURIComponent(assetID)}/preview?revision=${String(contentRevision)}`;
}

export function assetMediaURL(assetID: string, contentRevision: number): string {
  return `/v1/assets/${encodeURIComponent(assetID)}/media?revision=${String(contentRevision)}`;
}
