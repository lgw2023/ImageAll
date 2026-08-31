import { useState, type SyntheticEvent } from 'react';

import { RefreshCw, Search, SlidersHorizontal } from 'lucide-react';
import { NavLink } from 'react-router-dom';

import type { AssetMediaKind, AssetSort } from '@/api/contracts/asset';
import type { TagSummary } from '@/api/contracts/tag';

export type GalleryFilters = {
  searchText: string;
  sort: AssetSort;
  mediaKind: AssetMediaKind | null;
  acceptedTagID: string | null;
};

type GalleryToolbarProps = {
  filters: GalleryFilters;
  tags: TagSummary[];
  loadedCount: number;
  favoritesOnly: boolean;
  isRefreshing: boolean;
  onApply: (filters: GalleryFilters) => void;
  onRefresh: () => void;
};

export function GalleryToolbar({
  filters,
  tags,
  loadedCount,
  favoritesOnly,
  isRefreshing,
  onApply,
  onRefresh,
}: GalleryToolbarProps) {
  const [draftSearch, setDraftSearch] = useState(filters.searchText);
  const [filtersOpen, setFiltersOpen] = useState(false);

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
          placeholder="搜索照片"
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

        <div className="gallery-scope-switch" aria-label="图库范围">
          <NavLink className={!favoritesOnly ? 'active' : ''} end to="/gallery">
            全部
          </NavLink>
          <NavLink className={favoritesOnly ? 'active' : ''} to="/gallery/favorites">
            收藏
          </NavLink>
        </div>
      </div>

      <span className="gallery-result-count" aria-live="polite">
        已载入 {loadedCount.toLocaleString('zh-CN')} 项
      </span>
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
