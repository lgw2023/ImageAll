import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type MouseEvent,
  type PointerEvent,
} from 'react';

import { useVirtualizer } from '@tanstack/react-virtual';
import { Check, Film, Heart, ImageOff } from 'lucide-react';

import { assetThumbnailURL } from '@/api/assets';
import type { AssetSummary } from '@/api/contracts/asset';

import type { GalleryDensity } from './GalleryToolbar';
import { thumbnailLoader } from './thumbnailLoader';

type VirtualAssetGridProps = {
  assets: AssetSummary[];
  boxSelectionMode: boolean;
  density: GalleryDensity;
  selectedIDs: Set<string>;
  favoritePending: boolean;
  recoveryGeneration: number;
  hasNextPage: boolean;
  isFetchingNextPage: boolean;
  initialScrollOffset: number;
  onFetchNextPage: () => void;
  onOpen: (assetID: string) => void;
  onClearSelection: () => void;
  onSelectAll: () => void;
  onSelectIndices: (assetIndices: number[], additive: boolean) => void;
  onScrollOffset: (scrollOffset: number) => void;
  onToggleSelection: (assetIndex: number, range: boolean) => void;
  onFavorite: (asset: AssetSummary) => void;
  onThumbnailFailure: (url: string) => void;
};

function columnCount(width: number, density: GalleryDensity): number {
  if (density === 'compact') {
    if (width >= 1220) return 8;
    if (width >= 970) return 7;
    if (width >= 720) return 6;
    if (width >= 470) return 4;
    return 3;
  }
  if (width >= 1220) return 6;
  if (width >= 970) return 5;
  if (width >= 720) return 4;
  if (width >= 470) return 3;
  return 2;
}

function assetTitle(asset: AssetSummary): string {
  return asset.fileName ?? asset.relativePath ?? `照片 ${asset.id.slice(0, 8)}`;
}

function ManagedThumbnail({
  requestURL,
  failureURL,
  onFailure,
}: {
  requestURL: string;
  failureURL: string;
  onFailure: (url: string) => void;
}) {
  const [resolved, setResolved] = useState<{ requestURL: string; objectURL: string } | null>(null);

  useEffect(() => {
    let active = true;
    const lease = thumbnailLoader.acquire(requestURL);
    void lease.promise
      .then((objectURL) => {
        if (active) setResolved({ requestURL, objectURL });
      })
      .catch((error: unknown) => {
        if (active && !(error instanceof DOMException && error.name === 'AbortError')) {
          onFailure(failureURL);
        }
      });
    return () => {
      active = false;
      lease.release();
    };
  }, [failureURL, onFailure, requestURL]);

  const source = resolved?.requestURL === requestURL ? resolved.objectURL : null;
  return source ? (
    <img alt="" decoding="async" onError={() => onFailure(failureURL)} src={source} />
  ) : (
    <span aria-hidden="true" className="asset-thumbnail-loading" />
  );
}

export function VirtualAssetGrid({
  assets,
  boxSelectionMode,
  density,
  selectedIDs,
  favoritePending,
  recoveryGeneration,
  hasNextPage,
  isFetchingNextPage,
  initialScrollOffset,
  onFetchNextPage,
  onOpen,
  onClearSelection,
  onSelectAll,
  onSelectIndices,
  onScrollOffset,
  onToggleSelection,
  onFavorite,
  onThumbnailFailure,
}: VirtualAssetGridProps) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(900);
  const [activeIndex, setActiveIndex] = useState(0);
  const [contextMenu, setContextMenu] = useState<{ index: number; x: number; y: number } | null>(
    null,
  );
  const [selectionRectangle, setSelectionRectangle] = useState<{
    left: number;
    top: number;
    width: number;
    height: number;
  } | null>(null);
  const dragStart = useRef<{ x: number; y: number; pointerID: number } | null>(null);
  const suppressClick = useRef(false);
  const columns = columnCount(width, density);
  const gap = density === 'compact' ? 4 : 6;
  const cardWidth = Math.max(
    density === 'compact' ? 96 : 140,
    (width - gap * (columns - 1)) / columns,
  );
  const cardHeight = Math.round(cardWidth * 0.75);
  const rowHeight = cardHeight + gap;
  const rowCount = Math.ceil(assets.length / columns);
  // TanStack Virtual intentionally returns imperative functions that React Compiler skips.
  // eslint-disable-next-line react-hooks/incompatible-library
  const virtualizer = useVirtualizer({
    count: rowCount,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => rowHeight,
    initialOffset: initialScrollOffset,
    overscan: 2,
  });
  const virtualRows = virtualizer.getVirtualItems();

  useEffect(() => {
    const element = scrollRef.current;
    if (!element) return;
    const observer = new ResizeObserver(([entry]) => {
      if (entry) setWidth(entry.contentRect.width);
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const element = scrollRef.current;
    if (!element) return;
    const report = () => onScrollOffset(element.scrollTop);
    element.addEventListener('scroll', report, { passive: true });
    return () => {
      onScrollOffset(element.scrollTop);
      element.removeEventListener('scroll', report);
    };
  }, [onScrollOffset]);

  useEffect(() => {
    virtualizer.measure();
  }, [rowHeight, virtualizer]);

  useEffect(() => {
    if (!contextMenu) return;
    const close = () => setContextMenu(null);
    window.addEventListener('pointerdown', close);
    window.addEventListener('blur', close);
    return () => {
      window.removeEventListener('pointerdown', close);
      window.removeEventListener('blur', close);
    };
  }, [contextMenu]);

  useEffect(() => {
    const lastRow = virtualRows.at(-1)?.index ?? -1;
    if (lastRow >= rowCount - 2 && hasNextPage && !isFetchingNextPage) onFetchNextPage();
  }, [hasNextPage, isFetchingNextPage, onFetchNextPage, rowCount, virtualRows]);

  const focusIndex = useCallback(
    (nextIndex: number) => {
      if (!assets.length) return;
      const bounded = Math.max(0, Math.min(assets.length - 1, nextIndex));
      setActiveIndex(bounded);
      virtualizer.scrollToIndex(Math.floor(bounded / columns), { align: 'auto' });
      requestAnimationFrame(() => {
        scrollRef.current
          ?.querySelector<HTMLElement>(`[data-grid-index="${String(bounded)}"]`)
          ?.focus({ preventScroll: true });
      });
    },
    [assets.length, columns, virtualizer],
  );

  function handleCardKey(event: KeyboardEvent<HTMLButtonElement>, index: number) {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'a') {
      event.preventDefault();
      onSelectAll();
      return;
    }
    if (event.key === 'Escape') {
      event.preventDefault();
      onClearSelection();
      return;
    }
    const moves: Record<string, number> = {
      ArrowLeft: index - 1,
      ArrowRight: index + 1,
      ArrowUp: index - columns,
      ArrowDown: index + columns,
      Home: 0,
      End: assets.length - 1,
    };
    const nextIndex = moves[event.key];
    if (nextIndex !== undefined) {
      event.preventDefault();
      focusIndex(nextIndex);
    } else if (event.key === ' ') {
      event.preventDefault();
      onToggleSelection(index, event.shiftKey);
    }
  }

  function openContextMenu(event: MouseEvent<HTMLElement>, index: number) {
    event.preventDefault();
    setActiveIndex(index);
    setContextMenu({ index, x: event.clientX, y: event.clientY });
  }

  function startBoxSelection(event: PointerEvent<HTMLDivElement>) {
    if (
      !boxSelectionMode ||
      event.button !== 0 ||
      (event.target instanceof Element && event.target.closest('.asset-context-menu'))
    )
      return;
    event.preventDefault();
    event.stopPropagation();
    suppressClick.current = true;
    dragStart.current = { x: event.clientX, y: event.clientY, pointerID: event.pointerId };
    event.currentTarget.setPointerCapture(event.pointerId);
    setSelectionRectangle({ left: event.clientX, top: event.clientY, width: 0, height: 0 });
  }

  function updateBoxSelection(event: PointerEvent<HTMLDivElement>) {
    const start = dragStart.current;
    if (start?.pointerID !== event.pointerId) return;
    event.preventDefault();
    setSelectionRectangle({
      left: Math.min(start.x, event.clientX),
      top: Math.min(start.y, event.clientY),
      width: Math.abs(event.clientX - start.x),
      height: Math.abs(event.clientY - start.y),
    });
  }

  function finishBoxSelection(event: PointerEvent<HTMLDivElement>) {
    const start = dragStart.current;
    if (start?.pointerID !== event.pointerId) return;
    event.preventDefault();
    const bounds = {
      left: Math.min(start.x, event.clientX),
      right: Math.max(start.x, event.clientX),
      top: Math.min(start.y, event.clientY),
      bottom: Math.max(start.y, event.clientY),
    };
    const indices = [
      ...event.currentTarget.querySelectorAll<HTMLElement>('[data-grid-asset-index]'),
    ]
      .filter((element) => {
        const rect = element.closest<HTMLElement>('.asset-card')?.getBoundingClientRect();
        return (
          rect &&
          rect.right >= bounds.left &&
          rect.left <= bounds.right &&
          rect.bottom >= bounds.top &&
          rect.top <= bounds.bottom
        );
      })
      .map((element) => Number(element.dataset.gridAssetIndex))
      .filter(Number.isInteger);
    onSelectIndices(indices, event.metaKey || event.ctrlKey);
    dragStart.current = null;
    setSelectionRectangle(null);
    window.setTimeout(() => {
      suppressClick.current = false;
    }, 0);
  }

  const rows = useMemo(
    () =>
      virtualRows.map((row) => {
        const firstIndex = row.index * columns;
        return { row, items: assets.slice(firstIndex, firstIndex + columns), firstIndex };
      }),
    [assets, columns, virtualRows],
  );

  return (
    <div
      aria-colcount={columns}
      aria-label="照片网格"
      aria-rowcount={rowCount}
      className="asset-grid-scroll"
      data-box-selection={boxSelectionMode}
      data-density={density}
      onPointerDownCapture={startBoxSelection}
      onPointerMove={updateBoxSelection}
      onPointerUp={finishBoxSelection}
      ref={scrollRef}
      role="grid"
    >
      <div className="asset-grid-virtual" style={{ height: virtualizer.getTotalSize() }}>
        {rows.map(({ row, items, firstIndex }) => (
          <div
            aria-rowindex={row.index + 1}
            className="asset-grid-row"
            key={row.key}
            role="row"
            style={{
              gap,
              gridTemplateColumns: `repeat(${String(columns)}, minmax(0, 1fr))`,
              height: cardHeight,
              transform: `translateY(${String(row.start)}px)`,
            }}
          >
            {items.map((asset, columnIndex) => {
              const index = firstIndex + columnIndex;
              const title = assetTitle(asset);
              const selected = selectedIDs.has(asset.id);
              const isFavorite = asset.favorite?.isFavorite === true;
              const thumbnailURL = assetThumbnailURL(asset, Math.round(cardWidth * 2));
              const recoverySeparator = thumbnailURL.includes('?') ? '&' : '?';
              const thumbnailSource = `${thumbnailURL}${recoverySeparator}recoveryGeneration=${String(recoveryGeneration)}`;
              return (
                <article
                  aria-colindex={columnIndex + 1}
                  aria-selected={selected}
                  className="asset-card"
                  data-selected={selected}
                  key={asset.id}
                  onContextMenu={(event) => openContextMenu(event, index)}
                  role="gridcell"
                >
                  <button
                    aria-label={`查看 ${title}`}
                    className="asset-card-main"
                    data-asset-focus={asset.id}
                    data-grid-asset-index={index}
                    data-grid-index={index}
                    onClick={(event) => {
                      if (suppressClick.current || boxSelectionMode) return;
                      if (event.metaKey || event.ctrlKey) onToggleSelection(index, false);
                      else onOpen(asset.id);
                    }}
                    onDoubleClick={() => {
                      if (!boxSelectionMode) onOpen(asset.id);
                    }}
                    onFocus={() => setActiveIndex(index)}
                    onKeyDown={(event) => handleCardKey(event, index)}
                    tabIndex={index === activeIndex ? 0 : -1}
                    type="button"
                  >
                    <span className="asset-thumbnail">
                      {asset.availability === 'available' ? (
                        <ManagedThumbnail
                          failureURL={thumbnailURL}
                          onFailure={onThumbnailFailure}
                          requestURL={thumbnailSource}
                        />
                      ) : (
                        <span className="asset-unavailable">
                          <ImageOff aria-hidden="true" size={24} />
                          {asset.availability === 'missing' ? '文件不可用' : '无法预览'}
                        </span>
                      )}
                      {asset.mediaType.startsWith('video') ? (
                        <span className="asset-video-badge">
                          <Film aria-hidden="true" size={13} /> 视频
                        </span>
                      ) : null}
                    </span>
                    <span className="asset-card-copy">
                      <span className="asset-card-index" aria-hidden="true">
                        {String(index + 1).padStart(3, '0')}
                      </span>
                      <span className="asset-card-labels">
                        <strong title={title}>{title}</strong>
                        <span>{asset.sourceName}</span>
                      </span>
                    </span>
                  </button>
                  <button
                    aria-label={selected ? `取消选择 ${title}` : `选择 ${title}`}
                    aria-pressed={selected}
                    className="asset-select-button"
                    onClick={(event) => onToggleSelection(index, event.shiftKey)}
                    type="button"
                  >
                    <Check aria-hidden="true" size={15} />
                  </button>
                  {asset.favorite ? (
                    <button
                      aria-label={isFavorite ? `取消收藏 ${title}` : `收藏 ${title}`}
                      aria-pressed={isFavorite}
                      className="asset-favorite-button"
                      disabled={favoritePending}
                      onClick={() => onFavorite(asset)}
                      type="button"
                    >
                      <Heart
                        aria-hidden="true"
                        fill={isFavorite ? 'currentColor' : 'none'}
                        size={16}
                      />
                    </button>
                  ) : null}
                </article>
              );
            })}
          </div>
        ))}
      </div>
      {isFetchingNextPage ? <p className="grid-progress">正在载入更多照片…</p> : null}
      {selectionRectangle ? (
        <div className="asset-selection-rectangle" style={selectionRectangle} />
      ) : null}
      {contextMenu ? (
        <div
          aria-label="照片操作"
          className="asset-context-menu"
          onPointerDown={(event) => event.stopPropagation()}
          role="menu"
          style={{ left: contextMenu.x, top: contextMenu.y }}
        >
          <button
            autoFocus
            onClick={() => {
              const selectedAsset = assets[contextMenu.index];
              if (selectedAsset) onOpen(selectedAsset.id);
              setContextMenu(null);
            }}
            role="menuitem"
            type="button"
          >
            打开详情
          </button>
          <button
            onClick={() => {
              onToggleSelection(contextMenu.index, false);
              setContextMenu(null);
            }}
            role="menuitem"
            type="button"
          >
            {selectedIDs.has(assets[contextMenu.index]?.id ?? '') ? '取消选择' : '选择'}
          </button>
          <button
            disabled={!assets[contextMenu.index]?.favorite}
            onClick={() => {
              const selectedAsset = assets[contextMenu.index];
              if (selectedAsset) onFavorite(selectedAsset);
              setContextMenu(null);
            }}
            role="menuitem"
            type="button"
          >
            {assets[contextMenu.index]?.favorite?.isFavorite ? '取消收藏' : '收藏'}
          </button>
        </div>
      ) : null}
    </div>
  );
}
