import { useState, type SyntheticEvent } from 'react';

import { BoxSelect, RefreshCw, ScanSearch, Search, SlidersHorizontal } from 'lucide-react';
import { NavLink } from 'react-router-dom';

import type { AssetMediaKind, AssetSort, SourceFolder, SourceSummary } from '@/api/contracts/asset';
import type { TagSummary } from '@/api/contracts/tag';

export type GalleryDensity = 'comfortable' | 'compact';

export type GalleryFilters = {
  searchText: string;
  sort: AssetSort;
  mediaKind: AssetMediaKind | null;
  acceptedTagID: string | null;
  sourceID: string | null;
  folderRelativePath: string | null;
  density: GalleryDensity;
};

type GalleryToolbarProps = {
  filters: GalleryFilters;
  tags: TagSummary[];
  sources: SourceSummary[];
  folders: SourceFolder[];
  foldersLoading: boolean;
  searchQuery: string;
  loadedCount: number;
  favoritesOnly: boolean;
  isRefreshing: boolean;
  onApply: (filters: GalleryFilters) => void;
  onRefresh: () => void;
  onAnalyzeCurrentFilter: () => void;
  boxSelectionMode: boolean;
  onToggleBoxSelection: () => void;
};

export function GalleryToolbar({
  filters,
  tags,
  sources,
  folders,
  foldersLoading,
  searchQuery,
  loadedCount,
  favoritesOnly,
  isRefreshing,
  onApply,
  onRefresh,
  onAnalyzeCurrentFilter,
  boxSelectionMode,
  onToggleBoxSelection,
}: GalleryToolbarProps) {
  const [draftSearch, setDraftSearch] = useState(filters.searchText);
  const [filtersOpen, setFiltersOpen] = useState(false);
  const selectedSource = sources.find((source) => source.id === filters.sourceID) ?? null;
  const folderSegments = filters.folderRelativePath?.split('/').filter(Boolean) ?? [];
  const querySuffix = searchQuery ? `?${searchQuery}` : '';

  function submit(event: SyntheticEvent<HTMLFormElement, SubmitEvent>) {
    event.preventDefault();
    onApply({ ...filters, searchText: draftSearch.trim() });
  }

  return (
    <div className="gallery-toolbar" aria-label="图库工具栏">
      <form className="gallery-search" onSubmit={submit} role="search">
        <Search aria-hidden="true" size={16} />
        <label className="visually-hidden" htmlFor="gallery-search-input">
          搜索文件名或相对路径
        </label>
        <input
          id="gallery-search-input"
          onChange={(event) => setDraftSearch(event.target.value)}
          placeholder="搜索文件名、路径或记忆"
          type="search"
          value={draftSearch}
        />
      </form>

      <button
        aria-expanded={filtersOpen}
        className="button gallery-filter-toggle"
        onClick={() => setFiltersOpen((value) => !value)}
        type="button"
      >
        <SlidersHorizontal aria-hidden="true" size={16} /> 筛选
      </button>

      <div className="gallery-filter-controls" data-open={filtersOpen}>
        <label className="compact-field">
          <span>来源</span>
          <select
            onChange={(event) =>
              onApply({
                ...filters,
                sourceID: event.target.value || null,
                folderRelativePath: null,
              })
            }
            value={filters.sourceID ?? ''}
          >
            <option value="">全部来源</option>
            {sources.map((source) => (
              <option disabled={source.state !== 'active'} key={source.id} value={source.id}>
                {source.displayName}
                {source.state === 'active' ? '' : '（不可用）'}
              </option>
            ))}
          </select>
        </label>

        <label className="compact-field">
          <span>媒体</span>
          <select
            onChange={(event) =>
              onApply({
                ...filters,
                mediaKind: event.target.value ? (event.target.value as AssetMediaKind) : null,
              })
            }
            value={filters.mediaKind ?? ''}
          >
            <option value="">全部</option>
            <option value="image">照片</option>
            <option value="video">视频</option>
          </select>
        </label>

        <label className="compact-field">
          <span>标签</span>
          <select
            onChange={(event) => onApply({ ...filters, acceptedTagID: event.target.value || null })}
            value={filters.acceptedTagID ?? ''}
          >
            <option value="">全部标签</option>
            {tags.map((tag) => (
              <option key={tag.id} value={tag.id}>
                {tag.displayName}
              </option>
            ))}
          </select>
        </label>

        <label className="compact-field">
          <span>排序</span>
          <select
            onChange={(event) => onApply({ ...filters, sort: event.target.value as AssetSort })}
            value={filters.sort}
          >
            <option value="newest">最新优先</option>
            <option value="oldest">最早优先</option>
            <option value="fileNameAscending">文件名</option>
          </select>
        </label>

        <label className="compact-field">
          <span>视图</span>
          <select
            onChange={(event) =>
              onApply({ ...filters, density: event.target.value as GalleryDensity })
            }
            value={filters.density}
          >
            <option value="comfortable">舒适</option>
            <option value="compact">紧凑</option>
          </select>
        </label>

        <div className="gallery-scope-switch" aria-label="图库范围">
          <NavLink className={!favoritesOnly ? 'active' : ''} end to={`/gallery${querySuffix}`}>
            全部
          </NavLink>
          <NavLink
            className={favoritesOnly ? 'active' : ''}
            to={`/gallery/favorites${querySuffix}`}
          >
            收藏
          </NavLink>
          <NavLink to="/gallery/overview">概览</NavLink>
        </div>
      </div>

      {selectedSource?.kind === 'folder' ? (
        <nav aria-label="文件夹层级" className="gallery-folder-browser">
          <span>文件夹</span>
          <button
            aria-current={filters.folderRelativePath ? undefined : 'page'}
            onClick={() => onApply({ ...filters, folderRelativePath: null })}
            type="button"
          >
            全部
          </button>
          {folderSegments.map((segment, index) => {
            const relativePath = folderSegments.slice(0, index + 1).join('/');
            return (
              <button
                aria-current={relativePath === filters.folderRelativePath ? 'page' : undefined}
                key={relativePath}
                onClick={() => onApply({ ...filters, folderRelativePath: relativePath })}
                type="button"
              >
                {segment}
              </button>
            );
          })}
          <label>
            <span className="visually-hidden">选择子文件夹</span>
            <select
              aria-label="选择子文件夹"
              disabled={foldersLoading || folders.length === 0}
              onChange={(event) => {
                if (event.target.value)
                  onApply({ ...filters, folderRelativePath: event.target.value });
              }}
              value=""
            >
              <option value="">
                {foldersLoading
                  ? '正在载入…'
                  : folders.length > 0
                    ? '进入子文件夹…'
                    : '没有子文件夹'}
              </option>
              {folders.map((folder) => (
                <option key={folder.relativePath} value={folder.relativePath}>
                  {folder.name}
                </option>
              ))}
            </select>
          </label>
        </nav>
      ) : null}

      <span className="gallery-result-count" aria-live="polite">
        已载入 {loadedCount.toLocaleString('zh-CN')} 项
      </span>
      <button className="button" onClick={onAnalyzeCurrentFilter} type="button">
        <ScanSearch aria-hidden="true" size={15} /> 分析当前筛选
      </button>
      <button
        aria-pressed={boxSelectionMode}
        className="button"
        onClick={onToggleBoxSelection}
        type="button"
      >
        <BoxSelect aria-hidden="true" size={15} /> 框选
      </button>
      <button
        aria-label="刷新图库"
        className="icon-button"
        disabled={isRefreshing}
        onClick={onRefresh}
        type="button"
      >
        <RefreshCw aria-hidden="true" className={isRefreshing ? 'spin' : ''} size={17} />
      </button>
    </div>
  );
}
