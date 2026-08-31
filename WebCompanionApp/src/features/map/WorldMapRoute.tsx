import { useEffect, useMemo, useRef, useState, type SyntheticEvent } from 'react';

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Image as ImageIcon, LocateFixed, MapPin, RefreshCw, Search, Square } from 'lucide-react';
import { useNavigate } from 'react-router-dom';

import type {
  LocationBackfill,
  WorldMapBounds,
  WorldMapCluster,
  WorldMapPlaceResolution,
} from '@/api/contracts/map';
import { errorMessage } from '@/api/errors';
import {
  applyLocationBackfill,
  confirmWorldMapPlace,
  fetchLocationBackfills,
  fetchWorldMap,
  fetchWorldMapPlaces,
  fetchWorldMapSelection,
  searchWorldMapPlace,
} from '@/api/map';

type MapViewport = WorldMapBounds & {
  centerLongitude?: number;
  centerLatitude?: number;
  zoom?: number;
  bearing?: number;
  pitch?: number;
};

type MapRenderer = {
  updateClusters: (payload: { clusters: WorldMapCluster[] }) => void;
  restoreSelection: (clusterID: string | null) => void;
  restoreViewport?: (viewport: MapViewport) => void;
};

function isMapRenderer(candidate: unknown): candidate is MapRenderer {
  return Boolean(
    candidate &&
    typeof candidate === 'object' &&
    'updateClusters' in candidate &&
    typeof candidate.updateClusters === 'function' &&
    'restoreSelection' in candidate &&
    typeof candidate.restoreSelection === 'function',
  );
}

function mapRenderer(frame: HTMLIFrameElement | null): MapRenderer | undefined {
  const contentWindow = frame?.contentWindow;
  if (!contentWindow) return undefined;
  const candidate: unknown = Reflect.get(contentWindow, 'ImageAllWorldMap');
  return isMapRenderer(candidate) ? candidate : undefined;
}

function finiteBounds(value: unknown): MapViewport | null {
  if (!value || typeof value !== 'object') return null;
  const input = value as Record<string, unknown>;
  const bounds = [input.west, input.south, input.east, input.north];
  if (!bounds.every((item) => typeof item === 'number' && Number.isFinite(item))) return null;
  const result = { ...input } as MapViewport;
  if (result.south >= result.north || result.south < -90 || result.north > 90) return null;
  return result;
}

function MapCanvas({
  clusters,
  selectedClusterID,
  onSelect,
  onViewport,
}: {
  clusters: WorldMapCluster[];
  selectedClusterID: string | null;
  onSelect: (clusterID: string) => void;
  onViewport: (viewport: MapViewport) => void;
}) {
  const frameRef = useRef<HTMLIFrameElement>(null);
  const [rendererState, setRendererState] = useState<'connecting' | 'ready' | 'failed'>(
    'connecting',
  );

  useEffect(() => {
    function receive(event: MessageEvent<unknown>) {
      const data = event.data;
      if (
        event.origin !== window.location.origin ||
        event.source !== frameRef.current?.contentWindow ||
        !data ||
        typeof data !== 'object' ||
        !('type' in data) ||
        data.type !== 'imageall-world-map-event' ||
        !('payload' in data) ||
        !data.payload ||
        typeof data.payload !== 'object'
      )
        return;
      const message = data.payload as Record<string, unknown>;
      if (message.type === 'ready') {
        setRendererState('ready');
        const renderer = mapRenderer(frameRef.current);
        renderer?.updateClusters({ clusters });
        renderer?.restoreSelection(selectedClusterID);
        const stored = sessionStorage.getItem('imageall-web-v2-map-viewport');
        if (stored) {
          try {
            const viewport = finiteBounds(JSON.parse(stored));
            if (viewport) renderer?.restoreViewport?.(viewport);
          } catch {
            sessionStorage.removeItem('imageall-web-v2-map-viewport');
          }
        }
      }
      if (message.type === 'renderError') setRendererState('failed');
      if (message.type === 'clusterClicked' && typeof message.clusterID === 'string')
        onSelect(message.clusterID);
      if (message.type === 'cameraChanged') {
        const viewport = finiteBounds(message.viewport);
        if (viewport) {
          sessionStorage.setItem('imageall-web-v2-map-viewport', JSON.stringify(viewport));
          onViewport(viewport);
        }
      }
    }
    window.addEventListener('message', receive);
    return () => window.removeEventListener('message', receive);
  }, [clusters, onSelect, onViewport, selectedClusterID]);

  useEffect(() => {
    const renderer = mapRenderer(frameRef.current);
    if (rendererState === 'ready') {
      renderer?.updateClusters({ clusters });
      renderer?.restoreSelection(selectedClusterID);
    }
  }, [clusters, rendererState, selectedClusterID]);

  return (
    <div className="map-canvas-shell">
      <iframe
        className="map-canvas-frame"
        onError={() => setRendererState('failed')}
        ref={frameRef}
        src="/world-map/index.html"
        title="照片世界地图"
      />
      {rendererState !== 'ready' ? (
        <div className="map-renderer-status" role={rendererState === 'failed' ? 'alert' : 'status'}>
          <strong>{rendererState === 'failed' ? '地图渲染器不可用' : '正在连接地图渲染器'}</strong>
          <span>地点列表仍可用于选择和浏览照片。</span>
        </div>
      ) : null}
    </div>
  );
}

function galleryURL(cluster: WorldMapCluster): string {
  const parameters = new URLSearchParams({
    worldMapCellDegrees: String(cluster.selectionQuery.cellDegrees),
    worldMapLongitudeBucket: String(cluster.selectionQuery.longitudeBucket),
    worldMapLatitudeBucket: String(cluster.selectionQuery.latitudeBucket),
    worldMapMaximumAssets: String(cluster.selectionQuery.maximumAssets),
  });
  const bounds = cluster.selectionQuery.bounds;
  if (bounds) {
    parameters.set('worldMapWest', String(bounds.west));
    parameters.set('worldMapSouth', String(bounds.south));
    parameters.set('worldMapEast', String(bounds.east));
    parameters.set('worldMapNorth', String(bounds.north));
  }
  return `/gallery?${parameters.toString()}`;
}

function LocationBackfillPanel() {
  const queryClient = useQueryClient();
  const [message, setMessage] = useState('');
  const backfills = useQuery({
    queryKey: ['world-map-backfills'],
    queryFn: ({ signal }) => fetchLocationBackfills(signal),
    refetchInterval: (query) =>
      query.state.data?.some((row) => ['queued', 'running', 'cancelling'].includes(row.phase))
        ? 1500
        : false,
  });
  const action = useMutation({
    mutationFn: ({ sourceID, command }: { sourceID: string; command: 'start' | 'cancel' }) =>
      applyLocationBackfill(sourceID, command),
    onSuccess: (response) => {
      queryClient.setQueryData<LocationBackfill[]>(['world-map-backfills'], (current = []) =>
        current.map((row) =>
          row.sourceID === response.snapshot.sourceID ? response.snapshot : row,
        ),
      );
      setMessage(
        response.replayed
          ? 'Mac 已重放位置任务请求。'
          : response.snapshot.phase === 'queued' || response.snapshot.phase === 'running'
            ? 'Mac 已接收位置回填任务。'
            : 'Mac 已接收取消请求。',
      );
    },
    onError: (error) => setMessage(errorMessage(error)),
  });

  return (
    <section className="map-tool-panel" aria-labelledby="location-backfill-title">
      <div className="panel-title-row">
        <div>
          <h3 id="location-backfill-title">照片位置回填</h3>
          <p>仅由 Mac 读取来源元数据；网页不取得文件路径。</p>
        </div>
        <LocateFixed aria-hidden="true" size={19} />
      </div>
      {backfills.isPending ? (
        <p role="status">正在读取来源状态…</p>
      ) : backfills.isError ? (
        <div role="alert">
          <p>{errorMessage(backfills.error)}</p>
          <button className="button" onClick={() => void backfills.refetch()} type="button">
            重试
          </button>
        </div>
      ) : (
        <div className="map-source-list">
          {backfills.data.map((row) => {
            const active = ['queued', 'running', 'cancelling'].includes(row.phase);
            const completed = row.scanProgress?.completedUnitCount ?? row.inspectedPhotoCount;
            const total = row.scanProgress?.totalUnitCount ?? row.totalPhotoCount;
            return (
              <article className="map-source-row" key={row.sourceID}>
                <div className="row-heading">
                  <div>
                    <strong>{row.sourceDisplayName}</strong>
                    <span>
                      已检查 {completed.toLocaleString('zh-CN')} / {total.toLocaleString('zh-CN')} ·
                      已定位 {row.locatedPhotoCount.toLocaleString('zh-CN')}
                    </span>
                  </div>
                  <span className="state-pill" data-state={row.phase}>
                    {row.phase}
                  </span>
                </div>
                {total > 0 ? (
                  <progress
                    aria-label={`${row.sourceDisplayName}位置回填进度`}
                    max={total}
                    value={completed}
                  />
                ) : null}
                <div className="inline-actions">
                  {row.canStart ? (
                    <button
                      className="button"
                      disabled={action.isPending}
                      onClick={() => action.mutate({ sourceID: row.sourceID, command: 'start' })}
                      type="button"
                    >
                      <LocateFixed aria-hidden="true" size={14} /> 开始回填
                    </button>
                  ) : null}
                  {row.canCancel ? (
                    <button
                      className="button button-danger"
                      disabled={action.isPending || !active}
                      onClick={() => action.mutate({ sourceID: row.sourceID, command: 'cancel' })}
                      type="button"
                    >
                      <Square aria-hidden="true" size={13} /> 取消
                    </button>
                  ) : null}
                </div>
              </article>
            );
          })}
        </div>
      )}
      <p aria-live="polite" className="form-status">
        {message}
      </p>
    </section>
  );
}

function replaceResolution(
  current: { items: WorldMapPlaceResolution[]; maximumQueryLength: number } | undefined,
  resolution: WorldMapPlaceResolution,
) {
  if (!current) return current;
  return {
    ...current,
    items: current.items.map((item) => (item.tagID === resolution.tagID ? resolution : item)),
  };
}

function PlaceTagPanel() {
  const queryClient = useQueryClient();
  const [query, setQuery] = useState('');
  const [message, setMessage] = useState('');
  const places = useQuery({
    queryKey: ['world-map-places'],
    queryFn: ({ signal }) => fetchWorldMapPlaces(signal),
  });
  const selected = places.data?.items[0] ?? null;
  const search = useMutation({
    mutationFn: ({ tagID, value }: { tagID: string; value: string }) =>
      searchWorldMapPlace(tagID, value),
    onSuccess: (response) => {
      queryClient.setQueryData(['world-map-places'], (current) =>
        replaceResolution(
          current as { items: WorldMapPlaceResolution[]; maximumQueryLength: number } | undefined,
          response.resolution,
        ),
      );
      setMessage('Mac 已返回地点候选。');
    },
    onError: (error) => setMessage(errorMessage(error)),
  });
  const confirm = useMutation({
    mutationFn: ({ tagID, placeID }: { tagID: string; placeID: string }) =>
      confirmWorldMapPlace(tagID, placeID),
    onSuccess: (response) => {
      queryClient.setQueryData(['world-map-places'], (current) =>
        replaceResolution(
          current as { items: WorldMapPlaceResolution[]; maximumQueryLength: number } | undefined,
          response.resolution,
        ),
      );
      setMessage(`已将“${response.resolution.tagName}”绑定到确认地点。`);
    },
    onError: (error) => setMessage(errorMessage(error)),
  });

  function submit(event: SyntheticEvent<HTMLFormElement, SubmitEvent>) {
    event.preventDefault();
    if (!selected || !query.trim()) return;
    setMessage('');
    search.mutate({ tagID: selected.tagID, value: query.trim() });
  }

  return (
    <section className="map-tool-panel" aria-labelledby="place-tags-title">
      <div className="panel-title-row">
        <div>
          <h3 id="place-tags-title">地方标签解析</h3>
          <p>搜索结果由 Mac 返回，确认前不会改变标签绑定。</p>
        </div>
        <Search aria-hidden="true" size={19} />
      </div>
      {places.isPending ? (
        <p role="status">正在读取地方标签…</p>
      ) : places.isError ? (
        <div role="alert">
          <p>{errorMessage(places.error)}</p>
          <button className="button" onClick={() => void places.refetch()} type="button">
            重试
          </button>
        </div>
      ) : !selected ? (
        <p className="panel-note">当前没有待解析的地方标签。</p>
      ) : (
        <>
          <div className="place-tag-summary">
            <div>
              <strong>{selected.tagName}</strong>
              <span>
                {selected.groupName} · {selected.acceptedPhotoCount.toLocaleString('zh-CN')} 张照片
              </span>
            </div>
            <span className="state-pill" data-state={selected.status}>
              {selected.status}
            </span>
          </div>
          <form className="place-search" onSubmit={submit}>
            <label>
              <span>搜索地点</span>
              <input
                maxLength={places.data.maximumQueryLength}
                onChange={(event) => setQuery(event.target.value)}
                placeholder={`${selected.tagName} 中国`}
                value={query}
              />
            </label>
            <button className="button" disabled={!query.trim() || search.isPending} type="submit">
              搜索
            </button>
          </form>
          <div className="place-candidate-list">
            {selected.candidates.map((candidate) => (
              <div className="place-candidate" key={candidate.placeID}>
                <div>
                  <strong>{candidate.displayName}</strong>
                  <span>{candidate.subtitle ?? candidate.kind}</span>
                </div>
                <button
                  className="button button-primary"
                  disabled={confirm.isPending || selected.confirmedPlaceID === candidate.placeID}
                  onClick={() =>
                    confirm.mutate({ tagID: selected.tagID, placeID: candidate.placeID })
                  }
                  type="button"
                >
                  {selected.confirmedPlaceID === candidate.placeID ? '已确认' : '确认地点'}
                </button>
              </div>
            ))}
          </div>
        </>
      )}
      <p aria-live="polite" className="form-status">
        {message}
      </p>
    </section>
  );
}

export function WorldMapRoute() {
  const navigate = useNavigate();
  const [requestedBounds, setRequestedBounds] = useState<WorldMapBounds | null>(null);
  const [viewport, setViewport] = useState<MapViewport | null>(null);
  const [selectedClusterID, setSelectedClusterID] = useState<string | null>(null);
  const map = useQuery({
    queryKey: ['world-map', requestedBounds],
    queryFn: ({ signal }) => fetchWorldMap(requestedBounds, signal),
  });
  const clusters = useMemo(() => map.data?.clusters ?? [], [map.data]);
  const selectedCluster =
    clusters.find((cluster) => cluster.id === selectedClusterID) ?? clusters[0] ?? null;
  const selection = useQuery({
    queryKey: ['world-map-selection', selectedCluster?.selectionQuery ?? null],
    queryFn: ({ signal }) => {
      if (!selectedCluster) throw new Error('未选择地图地点');
      return fetchWorldMapSelection(selectedCluster.selectionQuery, signal);
    },
    enabled: Boolean(selectedCluster),
  });

  return (
    <section className="domain-workspace map-workspace" aria-labelledby="world-map-title">
      <header className="domain-heading map-heading">
        <div>
          <p className="eyebrow">工具</p>
          <h2 id="world-map-title">世界地图</h2>
          <p>地图只显示 Mac Host 提供的位置聚合；网页不会请求浏览器定位。</p>
        </div>
        <div className="inline-actions">
          {viewport ? (
            <button
              className="button"
              onClick={() =>
                setRequestedBounds({
                  west: viewport.west,
                  south: viewport.south,
                  east: viewport.east,
                  north: viewport.north,
                })
              }
              type="button"
            >
              刷新当前视口
            </button>
          ) : null}
          <button className="button" onClick={() => void map.refetch()} type="button">
            <RefreshCw aria-hidden="true" size={14} /> 刷新
          </button>
        </div>
      </header>
      {map.isPending ? (
        <div className="workspace-state" role="status">
          正在载入照片地图…
        </div>
      ) : map.isError ? (
        <div className="workspace-state workspace-state-error" role="alert">
          <strong>无法载入世界地图</strong>
          <p>{errorMessage(map.error)}</p>
          <button className="button" onClick={() => void map.refetch()} type="button">
            重试
          </button>
        </div>
      ) : (
        <>
          <div className="map-metrics" aria-label="位置统计">
            <div>
              <span>地点聚合</span>
              <strong>{clusters.length.toLocaleString('zh-CN')}</strong>
            </div>
            <div>
              <span>已定位照片</span>
              <strong>{map.data.locatedPhotoCount.toLocaleString('zh-CN')}</strong>
            </div>
            <div>
              <span>待定位照片</span>
              <strong>{map.data.unlocatedPhotoCount.toLocaleString('zh-CN')}</strong>
            </div>
          </div>
          <div className="map-browser">
            <MapCanvas
              clusters={clusters}
              onSelect={setSelectedClusterID}
              onViewport={setViewport}
              selectedClusterID={selectedCluster?.id ?? null}
            />
            <aside className="map-cluster-rail" aria-label="地图地点">
              <h3>地图地点</h3>
              {clusters.length ? (
                clusters.map((cluster) => (
                  <button
                    aria-current={selectedCluster?.id === cluster.id ? 'true' : undefined}
                    className="map-cluster-button"
                    key={cluster.id}
                    onClick={() => setSelectedClusterID(cluster.id)}
                    type="button"
                  >
                    <MapPin aria-hidden="true" size={16} />
                    <span>
                      <strong>{cluster.displayName}</strong>
                      <small>
                        {cluster.photoCount.toLocaleString('zh-CN')} 张 · GPS{' '}
                        {cluster.gpsCount.toLocaleString('zh-CN')}
                      </small>
                    </span>
                  </button>
                ))
              ) : (
                <p className="panel-note">当前范围没有已定位照片。</p>
              )}
            </aside>
          </div>
          {selectedCluster ? (
            <section className="map-selection" aria-labelledby="map-selection-title">
              <div className="panel-title-row">
                <div>
                  <p className="eyebrow">当前地点</p>
                  <h3 id="map-selection-title">{selectedCluster.displayName}</h3>
                  <p>
                    GPS {selectedCluster.gpsCount.toLocaleString('zh-CN')} · 地方标签{' '}
                    {selectedCluster.tagCount.toLocaleString('zh-CN')}
                  </p>
                </div>
                <button
                  className="button button-primary"
                  disabled={!selection.data?.totalPhotoCount}
                  onClick={() =>
                    void navigate(galleryURL(selectedCluster), {
                      state: { fromMap: true, mapLabel: selectedCluster.displayName },
                    })
                  }
                  type="button"
                >
                  在图库查看全部 {selection.data?.totalPhotoCount ?? selectedCluster.photoCount} 张
                </button>
              </div>
              {selection.isPending ? (
                <p role="status">正在读取地点照片…</p>
              ) : selection.isError ? (
                <div role="alert">
                  <p>{errorMessage(selection.error)}</p>
                  <button className="button" onClick={() => void selection.refetch()} type="button">
                    重试
                  </button>
                </div>
              ) : (
                <div className="map-photo-strip" aria-label="地点照片预览">
                  {selection.data.assets.map((asset) => (
                    <button
                      className="map-photo-card"
                      key={asset.id}
                      onClick={() => void navigate(`/assets/${encodeURIComponent(asset.id)}`)}
                      type="button"
                    >
                      {asset.availability === 'available' ? (
                        <img
                          alt=""
                          src={`/v1/assets/${encodeURIComponent(asset.id)}/thumbnail?w=240&revision=${String(asset.contentRevision)}`}
                        />
                      ) : (
                        <span className="map-photo-unavailable">
                          <ImageIcon aria-hidden="true" size={22} /> 不可预览
                        </span>
                      )}
                      <span>{asset.fileName ?? '未命名照片'}</span>
                    </button>
                  ))}
                </div>
              )}
            </section>
          ) : null}
          <div className="map-tools-grid">
            <LocationBackfillPanel />
            <PlaceTagPanel />
          </div>
        </>
      )}
    </section>
  );
}
