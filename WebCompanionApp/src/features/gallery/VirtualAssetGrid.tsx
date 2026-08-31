import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react';

import { useVirtualizer } from '@tanstack/react-virtual';
import { Check, Film, Heart, ImageOff } from 'lucide-react';

import { assetThumbnailURL } from '@/api/assets';
import type { AssetSummary } from '@/api/contracts/asset';

type VirtualAssetGridProps = {
  assets: AssetSummary[];
  selectedIDs: Set<string>;
  favoritePending: boolean;
  recoveryGeneration: number;
  hasNextPage: boolean;
  isFetchingNextPage: boolean;
  onFetchNextPage: () => void;
  onOpen: (assetID: string) => void;
  onToggleSelection: (assetIndex: number, range: boolean) => void;
  onFavorite: (asset: AssetSummary) => void;
  onThumbnailFailure: (url: string) => void;
};

function columnCount(width: number): number {
  if (width >= 1220) return 6;
  if (width >= 970) return 5;
  if (width >= 720) return 4;
  if (width >= 470) return 3;
  return 2;
}

function assetTitle(asset: AssetSummary): string {
  return asset.fileName ?? asset.relativePath ?? `照片 ${asset.id.slice(0, 8)}`;
}

export function VirtualAssetGrid({
  assets,
  selectedIDs,
  favoritePending,
  recoveryGeneration,
  hasNextPage,
  isFetchingNextPage,
  onFetchNextPage,
  onOpen,
  onToggleSelection,
  onFavorite,
  onThumbnailFailure,
}: VirtualAssetGridProps) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(900);
  const [activeIndex, setActiveIndex] = useState(0);
  const columns = columnCount(width);
  const gap = 12;
  const cardWidth = Math.max(140, (width - gap * (columns - 1)) / columns);
  const rowHeight = cardWidth + 66 + gap;
  const rowCount = Math.ceil(assets.length / columns);
  // TanStack Virtual intentionally returns imperative functions that React Compiler skips.
  // eslint-disable-next-line react-hooks/incompatible-library
  const virtualizer = useVirtualizer({
    count: rowCount,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => rowHeight,
    overscan: 3,
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
    virtualizer.measure();
  }, [rowHeight, virtualizer]);

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
                  role="gridcell"
                >
                  <button
                    aria-label={`查看 ${title}`}
                    className="asset-card-main"
                    data-asset-focus={asset.id}
                    data-grid-index={index}
                    onClick={() => onOpen(asset.id)}
                    onFocus={() => setActiveIndex(index)}
                    onKeyDown={(event) => handleCardKey(event, index)}
                    tabIndex={index === activeIndex ? 0 : -1}
                    type="button"
                  >
                    <span className="asset-thumbnail">
                      {asset.availability === 'available' ? (
                        <img
                          alt=""
                          decoding="async"
                          loading="lazy"
                          onError={() => onThumbnailFailure(thumbnailURL)}
                          src={thumbnailSource}
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
                      <strong title={title}>{title}</strong>
                      <span>{asset.sourceName}</span>
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
    </div>
  );
}
