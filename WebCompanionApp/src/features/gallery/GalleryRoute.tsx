import { useEffect, useMemo, useRef, useState } from 'react';

import {
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
  type InfiniteData,
} from '@tanstack/react-query';
import { Heart, Images, MapPin, RotateCcw } from 'lucide-react';
import { useLocation, useNavigate, useParams, useSearchParams } from 'react-router-dom';

import {
  fetchAssetPage,
  fetchSourceFolders,
  fetchSources,
  mutateFavorites,
  retryFavoriteSync,
} from '@/api/assets';
import type { AssetDetail, AssetPage, AssetSort, AssetSummary } from '@/api/contracts/asset';
import type { WorldMapSelectionQuery } from '@/api/contracts/map';
import type { TagDecisionAction } from '@/api/contracts/tag';
import { errorMessage } from '@/api/errors';
import {
  applyTagDecision,
  createTagAndApply,
  fetchTagGroups,
  fetchTags,
  fetchTagSelection,
  undoTagDecision,
} from '@/api/tags';
import { prepareEmbeddings } from '@/api/training';
import { submitSlimmingRemoval } from '@/api/slimming';

import { AssetViewer } from './AssetViewer';
import { ActionToast } from './ActionToast';
import { AssetDeletionDialog } from './AssetDeletionDialog';
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
const galleryViewCache = new Map<string, { ids: Set<string>; scrollOffset: number }>();

function parseSort(value: string | null): AssetSort {
  if (value === 'oldest' || value === 'fileNameAscending') return value;
  return 'newest';
}

function parseSourceID(value: string | null): string | null {
  return value &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
    ? value
    : null;
}

function parseFolderRelativePath(value: string | null): string | null {
  return value === null || value.trim() === '' ? null : value;
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
      sourceID: parseSourceID(searchParameters.get('source')),
      folderRelativePath: parseFolderRelativePath(searchParameters.get('folder')),
      density: searchParameters.get('view') === 'compact' ? 'compact' : 'comfortable',
    }),
    [searchParameters],
  );
  const assetQuery = useMemo(
    () => ({
      searchText: filters.searchText,
      sort: filters.sort,
      mediaKind: filters.mediaKind,
      acceptedTagID: filters.acceptedTagID,
      sourceID: filters.sourceID,
      folderRelativePath: filters.sourceID ? filters.folderRelativePath : null,
      favoritesOnly,
      worldMapSelection,
    }),
    [favoritesOnly, filters, worldMapSelection],
  );
  const selectionSignature = JSON.stringify(assetQuery);
  const cachedView = galleryViewCache.get(selectionSignature);
  const [selection, setSelection] = useState<{ signature: string; ids: Set<string> }>({
    signature: selectionSignature,
    ids: new Set(cachedView?.ids ?? []),
  });
  const selectedIDs = selection.signature === selectionSignature ? selection.ids : EMPTY_SELECTION;
  const selectionAnchor = useRef<{ signature: string; index: number } | null>(null);
  const [selectedTagID, setSelectedTagID] = useState('');
  const [statusMessage, setStatusMessage] = useState('');
  const [undoID, setUndoID] = useState<string | null>(null);
  const [boxSelectionMode, setBoxSelectionMode] = useState(false);
  const [selectionDeletionRequested, setSelectionDeletionRequested] = useState(false);
  const thumbnailRecovery = useThumbnailRecovery();

  useEffect(() => {
    if (selection.signature !== selectionSignature) return;
    const cached = galleryViewCache.get(selectionSignature);
    galleryViewCache.set(selectionSignature, {
      ids: new Set(selection.ids),
      scrollOffset: cached?.scrollOffset ?? 0,
    });
  }, [selection, selectionSignature]);

  const tags = useQuery({
    queryKey: ['tags'],
    queryFn: ({ signal }) => fetchTags(signal),
    select: (items) => items.filter((tag) => tag.state === 'active'),
  });
  const tagGroups = useQuery({
    queryKey: ['tag-groups'],
    queryFn: ({ signal }) => fetchTagGroups(signal),
    staleTime: 60_000,
  });
  const sources = useQuery({
    queryKey: ['sources'],
    queryFn: ({ signal }) => fetchSources(signal),
  });
  const selectedSource = sources.data?.find((source) => source.id === filters.sourceID) ?? null;
  const sourceFolders = useQuery({
    queryKey: ['source-folders', filters.sourceID, filters.folderRelativePath],
    queryFn: ({ signal }) =>
      fetchSourceFolders(filters.sourceID ?? '', filters.folderRelativePath, signal),
    enabled: Boolean(filters.sourceID && selectedSource?.kind === 'folder'),
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
  const viewerAssetIndex = assetId ? assets.findIndex((asset) => asset.id === assetId) : -1;
  const previousViewerAsset = viewerAssetIndex > 0 ? (assets[viewerAssetIndex - 1] ?? null) : null;
  const nextViewerAsset = viewerAssetIndex >= 0 ? (assets[viewerAssetIndex + 1] ?? null) : null;
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
  const visibleFavoriteSyncCounts = useMemo(
    () =>
      assets.reduce(
        (counts, asset) => {
          if (asset.favorite?.syncStatus === 'pending') counts.pending += 1;
          if (asset.favorite?.syncStatus === 'failed') counts.failed += 1;
          return counts;
        },
        { pending: 0, failed: 0 },
      ),
    [assets],
  );
  const visibleFavoriteRetryCount =
    visibleFavoriteSyncCounts.pending + visibleFavoriteSyncCounts.failed;

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

  const favoriteRetryMutation = useMutation({
    mutationFn: retryFavoriteSync,
    onSuccess: (response) => {
      void queryClient.invalidateQueries({ queryKey: ['assets'] });
      void queryClient.invalidateQueries({ queryKey: ['asset'] });
      setStatusMessage(
        response.pendingCount > 0 || response.failedCount > 0
          ? `红心同步仍有 ${String(response.pendingCount)} 项等待、${String(response.failedCount)} 项失败。`
          : 'Photos 红心同步已完成。',
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

  const createTagMutation = useMutation({
    mutationFn: ({
      name,
      assetIDs,
      operationID,
    }: {
      name: string;
      assetIDs: string[];
      operationID: string;
    }) => createTagAndApply(name, assetIDs, operationID),
    onSuccess: (response) => {
      setUndoID(response.undoID);
      setStatusMessage(
        `已新增标签“${response.displayName}”并应用到 ${String(response.appliedAssetCount)} 项。`,
      );
      void queryClient.invalidateQueries({ queryKey: ['tags'] });
      void queryClient.invalidateQueries({ queryKey: ['assets'] });
      void queryClient.invalidateQueries({ queryKey: ['asset'] });
      void queryClient.invalidateQueries({ queryKey: ['tag-selection'] });
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

  const embeddingMutation = useMutation({
    mutationFn: async (assetIDs: string[]) => {
      const groups = new Map<'image' | 'video', string[]>([
        ['image', []],
        ['video', []],
      ]);
      for (const id of assetIDs) {
        const mediaType = assets.find((asset) => asset.id === id)?.mediaType ?? 'image/jpeg';
        groups.get(mediaType.startsWith('video/') ? 'video' : 'image')?.push(id);
      }
      const requests = [...groups].filter(([, ids]) => ids.length > 0);
      if (requests.length !== 1) {
        throw new Error('照片与视频需要分开准备特征；请先把图库筛选为单一媒体类型。');
      }
      const request = requests[0];
      if (!request) throw new Error('没有可准备的项目。');
      await prepareEmbeddings(request[0], request[1]);
      return request[1].length;
    },
    onSuccess: (assetCount) => {
      setStatusMessage(`已把 ${String(assetCount)} 项特征准备交给 Mac；可在“训练”中跟踪。`);
      void queryClient.invalidateQueries({ queryKey: ['embedding-preparation'] });
    },
  });

  function selectedMediaScope(assetIDs: string[]) {
    const groups = new Map<'image' | 'video', string[]>([
      ['image', []],
      ['video', []],
    ]);
    for (const id of assetIDs) {
      const mediaType = assets.find((asset) => asset.id === id)?.mediaType ?? 'image/jpeg';
      groups.get(mediaType.startsWith('video/') ? 'video' : 'image')?.push(id);
    }
    const requests = [...groups].filter(([, ids]) => ids.length > 0);
    if (requests.length !== 1) {
      throw new Error('照片与视频需要分开处理；请先把图库筛选为单一媒体类型。');
    }
    const request = requests[0];
    if (!request) throw new Error('没有可处理的项目。');
    return request;
  }

  const deletionMutation = useMutation({
    mutationFn: async (assetIDs: string[]) => {
      const [mediaKind, ids] = selectedMediaScope(assetIDs);
      return submitSlimmingRemoval({
        scope: 'gallerySelection',
        jobID: null,
        clusterID: null,
        mediaKind,
        assetIDs: ids,
        mode: 'releaseSourceSpace',
      });
    },
    onSuccess: (request) => {
      setStatusMessage(
        `Mac 已冻结 ${String(request.assetIDs.length)} 项选择并进入删除确认队列；这不代表删除已完成。`,
      );
      setSelection({ signature: selectionSignature, ids: new Set() });
      selectionAnchor.current = null;
      void queryClient.invalidateQueries({ queryKey: ['slimming-removals'] });
      void queryClient.invalidateQueries({ queryKey: ['slimming-recycle'] });
      void queryClient.invalidateQueries({ queryKey: ['assets'] });
    },
  });

  const mutationPending =
    favoriteMutation.isPending ||
    favoriteRetryMutation.isPending ||
    tagMutation.isPending ||
    createTagMutation.isPending ||
    undoMutation.isPending ||
    embeddingMutation.isPending ||
    deletionMutation.isPending;

  function openCurrentFilterAnalysis() {
    if (!filters.mediaKind) {
      setStatusMessage('请先把图库筛选为照片或视频，再分析当前筛选。');
      return;
    }
    const parameters = new URLSearchParams({
      section: 'analyze',
      mode: 'currentFilter',
      media: filters.mediaKind,
      filterSort: filters.sort,
    });
    if (filters.searchText) parameters.set('filterQ', filters.searchText);
    if (filters.acceptedTagID) parameters.set('filterTag', filters.acceptedTagID);
    if (filters.sourceID) parameters.set('filterSource', filters.sourceID);
    if (filters.sourceID && filters.folderRelativePath) {
      parameters.set('filterFolder', filters.folderRelativePath);
    }
    if (favoritesOnly) parameters.set('filterFavorite', 'favorited');
    void navigate(`/slimming?${parameters}`);
  }

  function openSeedAnalysis() {
    try {
      const [mediaKind, ids] = selectedMediaScope(selectedAssetIDs);
      const parameters = new URLSearchParams({
        section: 'analyze',
        mode: 'seeds',
        media: mediaKind,
        seedAssetIDs: ids.join(','),
        filterSort: filters.sort,
      });
      if (filters.searchText) parameters.set('filterQ', filters.searchText);
      if (filters.acceptedTagID) parameters.set('filterTag', filters.acceptedTagID);
      if (filters.sourceID) parameters.set('filterSource', filters.sourceID);
      if (filters.sourceID && filters.folderRelativePath) {
        parameters.set('filterFolder', filters.folderRelativePath);
      }
      if (favoritesOnly) parameters.set('filterFavorite', 'favorited');
      void navigate(`/slimming?${parameters}`);
    } catch (error) {
      setStatusMessage(errorMessage(error));
    }
  }

  function applyFilters(next: GalleryFilters) {
    const parameters = new URLSearchParams();
    if (next.searchText) parameters.set('q', next.searchText);
    if (next.sort !== 'newest') parameters.set('sort', next.sort);
    if (next.mediaKind) parameters.set('media', next.mediaKind);
    if (next.acceptedTagID) parameters.set('tag', next.acceptedTagID);
    if (next.sourceID) parameters.set('source', next.sourceID);
    if (next.sourceID && next.folderRelativePath) parameters.set('folder', next.folderRelativePath);
    if (next.density === 'compact') parameters.set('view', 'compact');
    appendWorldMapSelection(parameters, worldMapSelection);
    const nextSignature = JSON.stringify({
      searchText: next.searchText,
      sort: next.sort,
      mediaKind: next.mediaKind,
      acceptedTagID: next.acceptedTagID,
      sourceID: next.sourceID,
      folderRelativePath: next.sourceID ? next.folderRelativePath : null,
      favoritesOnly,
      worldMapSelection,
    });
    if (nextSignature !== selectionSignature) {
      setSelection({ signature: '', ids: new Set() });
      selectionAnchor.current = null;
    }
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

  function selectIndices(indices: number[], additive: boolean) {
    setSelection((current) => {
      const currentIDs = current.signature === selectionSignature ? current.ids : EMPTY_SELECTION;
      const next = additive ? new Set(currentIDs) : new Set<string>();
      for (const index of indices) {
        const selectedAsset = assets[index];
        if (selectedAsset) next.add(selectedAsset.id);
      }
      return { signature: selectionSignature, ids: next };
    });
    const last = indices.at(-1);
    if (last !== undefined)
      selectionAnchor.current = { signature: selectionSignature, index: last };
  }

  function clearSelection() {
    setSelection({ signature: selectionSignature, ids: new Set() });
    selectionAnchor.current = null;
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
      return true;
    } catch (error) {
      setStatusMessage(errorMessage(error));
      return false;
    }
  }

  async function createAndApplyTag(name: string, assetIDs: string[], operationID: string) {
    setStatusMessage('');
    await createTagMutation.mutateAsync({ name, assetIDs, operationID });
  }

  function undoLastTagDecision() {
    if (!undoID) return;
    void undoMutation.mutateAsync(undoID).catch((error: unknown) => {
      setStatusMessage(errorMessage(error));
    });
  }

  function openAsset(id: string) {
    returnFocusAssetID = id;
    const query = searchParameters.toString();
    void navigate(`/assets/${encodeURIComponent(id)}${query ? `?${query}` : ''}`, {
      state: { fromGallery: true, favoritesOnly },
    });
  }

  function navigateViewer(id: string) {
    returnFocusAssetID = id;
    const query = searchParameters.toString();
    void navigate(`/assets/${encodeURIComponent(id)}${query ? `?${query}` : ''}`, {
      replace: true,
      state: { ...locationState, fromGallery: true, favoritesOnly },
    });
  }

  function closeViewer() {
    if (locationState.fromGallery) void navigate(-1);
    else void navigate(favoritesOnly ? '/gallery/favorites' : '/gallery', { replace: true });
  }

  return (
    <section className="gallery-workspace" aria-labelledby="gallery-title">
      <div className="gallery-heading">
        <div className="gallery-title-lockup">
          <p className="eyebrow">LIBRARY / LIVE</p>
          <h2 id="gallery-title">{favoritesOnly ? '我的收藏' : '全部照片'}</h2>
          <span className="gallery-title-translation" aria-hidden="true">
            {favoritesOnly ? 'FAVORITES' : 'VISUAL MEMORY'}
          </span>
          <p>搜索、整理和重新发现你的每一段视觉记忆。</p>
        </div>
        <div className="gallery-heading-aside">
          <dl className="gallery-heading-stats">
            <div>
              <dt>LOADED</dt>
              <dd>{assets.length.toLocaleString('zh-CN')}</dd>
            </div>
            <div>
              <dt>SOURCE</dt>
              <dd>MAC · LIVE</dd>
            </div>
          </dl>
          {thumbnailRecovery.recovering ? (
            <span className="thumbnail-recovery-status" role="status">
              正在恢复可见缩略图…
            </span>
          ) : null}
        </div>
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
        boxSelectionMode={boxSelectionMode}
        folders={sourceFolders.data?.folders ?? []}
        foldersLoading={sourceFolders.isFetching}
        key={filters.searchText}
        favoritesOnly={favoritesOnly}
        filters={filters}
        isRefreshing={assetsQuery.isRefetching}
        loadedCount={assets.length}
        onApply={applyFilters}
        onAnalyzeCurrentFilter={openCurrentFilterAnalysis}
        onRefresh={() => void assetsQuery.refetch()}
        onToggleBoxSelection={() => setBoxSelectionMode((value) => !value)}
        searchQuery={searchParameters.toString()}
        sources={sources.data ?? []}
        tags={activeTags}
      />

      {sources.isError || sourceFolders.isError ? (
        <p className="gallery-scope-error" role="status">
          {errorMessage(sources.error ?? sourceFolders.error)}；图库其余范围仍可使用。
        </p>
      ) : null}

      {visibleFavoriteRetryCount > 0 ? (
        <section className="favorite-sync-banner" aria-label="红心同步状态">
          <div>
            <Heart aria-hidden="true" size={16} />
            <span>
              当前窗口有 {String(visibleFavoriteSyncCounts.pending)} 项等待同步、
              {String(visibleFavoriteSyncCounts.failed)} 项同步失败。
            </span>
          </div>
          <button
            aria-label={`重试红心同步：${String(visibleFavoriteRetryCount)} 项`}
            className="button"
            disabled={favoriteRetryMutation.isPending}
            onClick={() => {
              setStatusMessage('');
              void favoriteRetryMutation.mutateAsync().catch((error: unknown) => {
                setStatusMessage(errorMessage(error));
              });
            }}
            type="button"
          >
            <RotateCcw aria-hidden="true" size={14} />
            {favoriteRetryMutation.isPending ? '正在重试…' : '重试同步'}
          </button>
        </section>
      ) : null}

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
          boxSelectionMode={boxSelectionMode}
          density={filters.density}
          favoritePending={favoriteMutation.isPending}
          hasNextPage={assetsQuery.hasNextPage}
          isFetchingNextPage={assetsQuery.isFetchingNextPage}
          initialScrollOffset={cachedView?.scrollOffset ?? 0}
          onFavorite={(asset) =>
            void applyFavorite([asset.id], asset.favorite?.isFavorite !== true)
          }
          onFetchNextPage={() => void assetsQuery.fetchNextPage()}
          onOpen={openAsset}
          onClearSelection={clearSelection}
          onSelectAll={() =>
            selectIndices(
              assets.map((_, index) => index),
              false,
            )
          }
          onSelectIndices={selectIndices}
          onScrollOffset={(scrollOffset) => {
            galleryViewCache.set(selectionSignature, {
              ids: new Set(selectedIDs),
              scrollOffset,
            });
          }}
          onThumbnailFailure={thumbnailRecovery.reportFailure}
          onToggleSelection={toggleSelection}
          recoveryGeneration={thumbnailRecovery.generation}
          selectedIDs={selectedIDs}
        />
      ) : null}

      {selectedAssetIDs.length > 0 ? (
        <SelectionBar
          aggregate={selectedAggregate}
          selectedAssetIDs={selectedAssetIDs}
          onClear={() => {
            clearSelection();
          }}
          onFavorite={(isFavorite) => void applyFavorite(selectedAssetIDs, isFavorite)}
          onCreateTag={createAndApplyTag}
          onFindSimilar={openSeedAnalysis}
          onPrepareEmbeddings={() =>
            void embeddingMutation.mutateAsync(selectedAssetIDs).catch((error: unknown) => {
              setStatusMessage(errorMessage(error));
            })
          }
          onDelete={() => setSelectionDeletionRequested(true)}
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

      {selectionDeletionRequested && selectedAssetIDs.length > 0 ? (
        <AssetDeletionDialog
          fileName={`${String(selectedAssetIDs.length)} 个所选项目`}
          onCancel={() => setSelectionDeletionRequested(false)}
          onConfirm={async () => {
            await deletionMutation.mutateAsync(selectedAssetIDs);
          }}
        />
      ) : null}

      {statusMessage && !assetId ? (
        <ActionToast
          message={statusMessage}
          onDismiss={() => setStatusMessage('')}
          onUndo={undoLastTagDecision}
          undoAvailable={Boolean(undoID)}
          undoPending={undoMutation.isPending}
        />
      ) : null}

      {assetId ? (
        <AssetViewer
          assetID={assetId}
          nextAsset={nextViewerAsset}
          key={assetId}
          mutationPending={mutationPending}
          onClose={closeViewer}
          onCreateTag={createAndApplyTag}
          onDelete={async (id) => {
            await deletionMutation.mutateAsync([id]);
          }}
          onDismissStatus={() => setStatusMessage('')}
          onFavorite={(id, isFavorite) => applyFavorite([id], isFavorite)}
          onNavigate={navigateViewer}
          onTagDecision={applyDecision}
          onUndo={undoLastTagDecision}
          previousAsset={previousViewerAsset}
          statusMessage={statusMessage}
          tagCatalog={activeTags}
          tagGroups={tagGroups.data ?? []}
          undoAvailable={Boolean(undoID)}
          undoPending={undoMutation.isPending}
        />
      ) : null}
    </section>
  );
}
