import { useEffect, useMemo, useRef, useState } from 'react';

import {
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
  type InfiniteData,
} from '@tanstack/react-query';
import { Images, MapPin, RotateCcw } from 'lucide-react';
import { useLocation, useNavigate, useParams, useSearchParams } from 'react-router-dom';

import { fetchAssetPage, mutateFavorites } from '@/api/assets';
import type { AssetDetail, AssetPage, AssetSort, AssetSummary } from '@/api/contracts/asset';
import type { WorldMapSelectionQuery } from '@/api/contracts/map';
import type { TagDecisionAction } from '@/api/contracts/tag';
import { errorMessage } from '@/api/errors';
import { applyTagDecision, fetchTags, fetchTagSelection, undoTagDecision } from '@/api/tags';

import { AssetViewer } from './AssetViewer';
import { GalleryToolbar, type GalleryFilters } from './GalleryToolbar';
import { SelectionBar } from './SelectionBar';
import { useThumbnailRecovery } from './useThumbnailRecovery';
import { VirtualAssetGrid } from './VirtualAssetGrid';

type GalleryLocationState = {
  fromGallery?: boolean;
  favoritesOnly?: boolean;
  fromMap?: boolean;
  mapLabel?: string;
};

let returnFocusAssetID: string | null = null;
const EMPTY_SELECTION = new Set<string>();

function parseSort(value: string | null): AssetSort {
  if (value === 'oldest' || value === 'fileNameAscending') return value;
  return 'newest';
}

function parseWorldMapSelection(parameters: URLSearchParams): WorldMapSelectionQuery | null {
  const cellDegrees = Number(parameters.get('worldMapCellDegrees'));
  const longitudeBucket = Number(parameters.get('worldMapLongitudeBucket'));
  const latitudeBucket = Number(parameters.get('worldMapLatitudeBucket'));
  const maximumAssets = Number(parameters.get('worldMapMaximumAssets'));
  if (
    !Number.isFinite(cellDegrees) ||
    cellDegrees <= 0 ||
    !Number.isInteger(longitudeBucket) ||
    !Number.isInteger(latitudeBucket) ||
    !Number.isInteger(maximumAssets) ||
    maximumAssets <= 0
  )
    return null;
  const boundKeys = ['West', 'South', 'East', 'North'];
  const boundValues = boundKeys.map((key) => Number(parameters.get(`worldMap${key}`)));
  const hasBounds =
    boundKeys.every((key) => parameters.has(`worldMap${key}`)) &&
    boundValues.every(Number.isFinite);
  const [west, south, east, north] = boundValues;
  return {
    cellDegrees,
    longitudeBucket,
    latitudeBucket,
    maximumAssets,
    bounds:
      hasBounds &&
      west !== undefined &&
      south !== undefined &&
      east !== undefined &&
      north !== undefined
        ? { west, south, east, north }
        : null,
  };
}

function appendWorldMapSelection(
  parameters: URLSearchParams,
  selection: WorldMapSelectionQuery | null,
) {
  if (!selection) return;
  parameters.set('worldMapCellDegrees', String(selection.cellDegrees));
  parameters.set('worldMapLongitudeBucket', String(selection.longitudeBucket));
  parameters.set('worldMapLatitudeBucket', String(selection.latitudeBucket));
  parameters.set('worldMapMaximumAssets', String(selection.maximumAssets));
  if (selection.bounds) {
    parameters.set('worldMapWest', String(selection.bounds.west));
    parameters.set('worldMapSouth', String(selection.bounds.south));
    parameters.set('worldMapEast', String(selection.bounds.east));
    parameters.set('worldMapNorth', String(selection.bounds.north));
  }
}

function updateFavoritePages(
  existing: InfiniteData<AssetPage, string | null> | undefined,
  states: Map<string, NonNullable<AssetSummary['favorite']>>,
) {
  if (!existing) return existing;
  return {
    ...existing,
    pages: existing.pages.map((page) => ({
      ...page,
      items: page.items.map((asset) =>
        states.has(asset.id) ? { ...asset, favorite: states.get(asset.id) ?? null } : asset,
      ),
    })),
  };
}

export function GalleryRoute() {
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const location = useLocation();
  const locationState = (location.state ?? {}) as GalleryLocationState;
  const { assetId } = useParams<{ assetId: string }>();
  const [searchParameters, setSearchParameters] = useSearchParams();
  const favoritesOnly =
    location.pathname === '/gallery/favorites' ||
    (Boolean(assetId) && locationState.favoritesOnly === true);
  const worldMapSelection = useMemo(
    () => parseWorldMapSelection(searchParameters),
    [searchParameters],
  );
  const filters = useMemo<GalleryFilters>(
    () => ({
      searchText: searchParameters.get('q') ?? '',
      sort: parseSort(searchParameters.get('sort')),
      mediaKind:
        searchParameters.get('media') === 'image' || searchParameters.get('media') === 'video'
          ? (searchParameters.get('media') as 'image' | 'video')
          : null,
      acceptedTagID: searchParameters.get('tag'),
    }),
    [searchParameters],
  );
  const assetQuery = useMemo(
    () => ({
      ...filters,
      favoritesOnly,
      worldMapSelection,
    }),
    [favoritesOnly, filters, worldMapSelection],
  );
  const selectionSignature = JSON.stringify(assetQuery);
  const [selection, setSelection] = useState<{ signature: string; ids: Set<string> }>({
    signature: selectionSignature,
    ids: new Set(),
  });
  const selectedIDs = selection.signature === selectionSignature ? selection.ids : EMPTY_SELECTION;
  const selectionAnchor = useRef<{ signature: string; index: number } | null>(null);
  const [selectedTagID, setSelectedTagID] = useState('');
  const [statusMessage, setStatusMessage] = useState('');
  const [undoID, setUndoID] = useState<string | null>(null);
  const thumbnailRecovery = useThumbnailRecovery();

  const tags = useQuery({
    queryKey: ['tags'],
    queryFn: ({ signal }) => fetchTags(signal),
    select: (items) => items.filter((tag) => tag.state === 'active'),
  });
  const assetsQuery = useInfiniteQuery({
    queryKey: ['assets', assetQuery],
    queryFn: ({ pageParam, signal }) => fetchAssetPage(assetQuery, pageParam, signal),
    initialPageParam: null as string | null,
    getNextPageParam: (page) => page.nextCursor ?? undefined,
  });
  const assets = useMemo(() => {
    const seen = new Set<string>();
    return (assetsQuery.data?.pages.flatMap((page) => page.items) ?? []).filter((asset) => {
      if (seen.has(asset.id)) return false;
      seen.add(asset.id);
      return true;
    });
  }, [assetsQuery.data]);
  const activeTags = useMemo(() => tags.data ?? [], [tags.data]);
  const effectiveSelectedTagID = activeTags.some((tag) => tag.id === selectedTagID)
    ? selectedTagID
    : (activeTags[0]?.id ?? '');

  useEffect(() => {
    if (assetId || !returnFocusAssetID) return;
    const focusID = returnFocusAssetID;
    returnFocusAssetID = null;
    requestAnimationFrame(() => {
      document
        .querySelector<HTMLElement>(`[data-asset-focus="${CSS.escape(focusID)}"]`)
        ?.focus({ preventScroll: true });
    });
  }, [assetId]);

  const selectedAssetIDs = useMemo(() => [...selectedIDs], [selectedIDs]);
  const selectionAggregate = useQuery({
    queryKey: ['tag-selection', activeTags.map((tag) => tag.id), selectedAssetIDs],
    queryFn: ({ signal }) =>
      fetchTagSelection(
        activeTags.map((tag) => tag.id),
        selectedAssetIDs,
        signal,
      ),
    enabled: activeTags.length > 0 && selectedAssetIDs.length > 0,
  });
  const selectedAggregate =
    selectionAggregate.data?.find((aggregate) => aggregate.tagID === effectiveSelectedTagID) ??
    null;

  const favoriteMutation = useMutation({
    mutationFn: ({ assetIDs, isFavorite }: { assetIDs: string[]; isFavorite: boolean }) =>
      mutateFavorites(assetIDs, isFavorite),
    onSuccess: (response) => {
      const states = new Map(response.states.map((state) => [state.assetID, state]));
      queryClient.setQueriesData<InfiniteData<AssetPage, string | null>>(
        { queryKey: ['assets'] },
        (existing) => updateFavoritePages(existing, states),
      );
      for (const state of response.states) {
        queryClient.setQueryData<AssetDetail>(['asset', state.assetID], (existing) =>
          existing ? { ...existing, favorite: state } : existing,
        );
      }
      void queryClient.invalidateQueries({ queryKey: ['assets'] });
      setStatusMessage(
        response.failedCount > 0
          ? `已更新 ${String(response.changedCount)} 项；${String(response.failedCount)} 项同步失败，可稍后重试。`
          : `已更新 ${String(response.changedCount)} 项收藏状态。`,
      );
    },
  });

  const tagMutation = useMutation({
    mutationFn: ({
      tagID,
      assetIDs,
      action,
    }: {
      tagID: string;
      assetIDs: string[];
      action: TagDecisionAction;
    }) => applyTagDecision(tagID, assetIDs, action),
    onSuccess: (response, variables) => {
      setUndoID(response.undoID);
      setStatusMessage(`已更新 ${String(response.appliedAssetCount)} 项标签决定。`);
      void queryClient.invalidateQueries({ queryKey: ['assets'] });
      void queryClient.invalidateQueries({ queryKey: ['tag-selection'] });
      for (const id of variables.assetIDs) {
        void queryClient.invalidateQueries({ queryKey: ['asset', id] });
      }
    },
  });

  const undoMutation = useMutation({
    mutationFn: (id: string) => undoTagDecision(id),
    onSuccess: (response) => {
      setUndoID(null);
      setStatusMessage(`已撤销并恢复 ${String(response.restoredAssetCount)} 项。`);
      void queryClient.invalidateQueries({ queryKey: ['assets'] });
      void queryClient.invalidateQueries({ queryKey: ['asset'] });
      void queryClient.invalidateQueries({ queryKey: ['tag-selection'] });
    },
  });

  const mutationPending =
    favoriteMutation.isPending || tagMutation.isPending || undoMutation.isPending;

  function applyFilters(next: GalleryFilters) {
    const parameters = new URLSearchParams();
    if (next.searchText) parameters.set('q', next.searchText);
    if (next.sort !== 'newest') parameters.set('sort', next.sort);
    if (next.mediaKind) parameters.set('media', next.mediaKind);
    if (next.acceptedTagID) parameters.set('tag', next.acceptedTagID);
    appendWorldMapSelection(parameters, worldMapSelection);
    setSelection({ signature: '', ids: new Set() });
    selectionAnchor.current = null;
    setSearchParameters(parameters);
  }

  function toggleSelection(index: number, range: boolean) {
    const asset = assets[index];
    if (!asset) return;
    setSelection((current) => {
      const currentIDs = current.signature === selectionSignature ? current.ids : EMPTY_SELECTION;
      const next = new Set(currentIDs);
      if (range && selectionAnchor.current?.signature === selectionSignature) {
        const start = Math.min(selectionAnchor.current.index, index);
        const end = Math.max(selectionAnchor.current.index, index);
        for (let itemIndex = start; itemIndex <= end; itemIndex += 1) {
          const rangeAsset = assets[itemIndex];
          if (rangeAsset) next.add(rangeAsset.id);
        }
      } else if (next.has(asset.id)) {
        next.delete(asset.id);
      } else {
        next.add(asset.id);
      }
      return { signature: selectionSignature, ids: next };
    });
    selectionAnchor.current = { signature: selectionSignature, index };
  }

  async function applyFavorite(assetIDs: string[], isFavorite: boolean) {
    setStatusMessage('');
    try {
      await favoriteMutation.mutateAsync({ assetIDs, isFavorite });
    } catch (error) {
      setStatusMessage(errorMessage(error));
    }
  }

  async function applyDecision(tagID: string, assetIDs: string[], action: TagDecisionAction) {
    setStatusMessage('');
    try {
      await tagMutation.mutateAsync({ tagID, assetIDs, action });
    } catch (error) {
      setStatusMessage(errorMessage(error));
    }
  }

  function openAsset(id: string) {
    returnFocusAssetID = id;
    const query = searchParameters.toString();
    void navigate(`/assets/${encodeURIComponent(id)}${query ? `?${query}` : ''}`, {
      state: { fromGallery: true, favoritesOnly },
    });
  }

  function closeViewer() {
    if (locationState.fromGallery) void navigate(-1);
    else void navigate(favoritesOnly ? '/gallery/favorites' : '/gallery', { replace: true });
  }

  return (
    <section className="gallery-workspace" aria-labelledby="gallery-title">
      <div className="gallery-heading">
        <div>
          <p className="eyebrow">照片</p>
          <h2 id="gallery-title">{favoritesOnly ? '收藏图库' : '图库'}</h2>
          <p>分页浏览、筛选和处理由 Mac Host 提供的照片投影。</p>
        </div>
        {thumbnailRecovery.recovering ? (
          <span className="thumbnail-recovery-status" role="status">
            正在恢复可见缩略图…
          </span>
        ) : null}
      </div>

      {worldMapSelection ? (
        <div className="map-gallery-banner">
          <MapPin aria-hidden="true" size={17} />
          <div>
            <strong>{locationState.mapLabel ?? '地图地点范围'}</strong>
            <span>图库结果保持地图聚合边界，可继续叠加筛选。</span>
          </div>
          <button
            className="button"
            onClick={() => {
              if (locationState.fromMap) void navigate(-1);
              else void navigate('/map');
            }}
            type="button"
          >
            返回世界地图
          </button>
        </div>
      ) : null}

      <GalleryToolbar
        key={filters.searchText}
        favoritesOnly={favoritesOnly}
        filters={filters}
        isRefreshing={assetsQuery.isRefetching}
        loadedCount={assets.length}
        onApply={applyFilters}
        onRefresh={() => void assetsQuery.refetch()}
        tags={activeTags}
      />

      {assetsQuery.isPending ? (
        <div className="gallery-loading" role="status">
          <span className="spinner" aria-hidden="true" />
          正在载入图库…
        </div>
      ) : null}
      {assetsQuery.isError ? (
        <div className="gallery-error" role="alert">
          <Images aria-hidden="true" size={24} />
          <div>
            <strong>无法载入图库</strong>
            <p>{errorMessage(assetsQuery.error)}</p>
          </div>
          <button className="button" onClick={() => void assetsQuery.refetch()} type="button">
            重试
          </button>
        </div>
      ) : null}
      {!assetsQuery.isPending && !assetsQuery.isError && assets.length === 0 ? (
        <div className="gallery-empty">
          <Images aria-hidden="true" size={28} />
          <h3>{favoritesOnly ? '还没有收藏照片' : '没有符合条件的照片'}</h3>
          <p>调整搜索或筛选条件后重试。</p>
        </div>
      ) : null}
      {assets.length > 0 ? (
        <VirtualAssetGrid
          assets={assets}
          favoritePending={favoriteMutation.isPending}
          hasNextPage={assetsQuery.hasNextPage}
          isFetchingNextPage={assetsQuery.isFetchingNextPage}
          onFavorite={(asset) =>
            void applyFavorite([asset.id], asset.favorite?.isFavorite !== true)
          }
          onFetchNextPage={() => void assetsQuery.fetchNextPage()}
          onOpen={openAsset}
          onThumbnailFailure={thumbnailRecovery.reportFailure}
          onToggleSelection={toggleSelection}
          recoveryGeneration={thumbnailRecovery.generation}
          selectedIDs={selectedIDs}
        />
      ) : null}

      {selectedAssetIDs.length > 0 ? (
        <SelectionBar
          aggregate={selectedAggregate}
          onClear={() => {
            setSelection({ signature: selectionSignature, ids: new Set() });
            selectionAnchor.current = null;
          }}
          onFavorite={(isFavorite) => void applyFavorite(selectedAssetIDs, isFavorite)}
          onSelectedTagChange={setSelectedTagID}
          onTagDecision={(action) =>
            void applyDecision(effectiveSelectedTagID, selectedAssetIDs, action)
          }
          pending={mutationPending || selectionAggregate.isFetching}
          selectedCount={selectedAssetIDs.length}
          selectedTagID={effectiveSelectedTagID}
          tags={activeTags}
        />
      ) : null}

      {statusMessage ? (
        <div className="action-toast" role="status">
          <span>{statusMessage}</span>
          {undoID ? (
            <button
              className="button"
              disabled={undoMutation.isPending}
              onClick={() => {
                void undoMutation.mutateAsync(undoID).catch((error: unknown) => {
                  setStatusMessage(errorMessage(error));
                });
              }}
              type="button"
            >
              <RotateCcw aria-hidden="true" size={14} /> 撤销
            </button>
          ) : null}
          <button
            aria-label="关闭消息"
            className="icon-button"
            onClick={() => setStatusMessage('')}
            type="button"
          >
            ×
          </button>
        </div>
      ) : null}

      {assetId ? (
        <AssetViewer
          assetID={assetId}
          key={assetId}
          mutationPending={mutationPending}
          onClose={closeViewer}
          onFavorite={(id, isFavorite) => applyFavorite([id], isFavorite)}
          onTagDecision={applyDecision}
        />
      ) : null}
    </section>
  );
}
