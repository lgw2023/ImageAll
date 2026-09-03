import { useState, type SyntheticEvent } from 'react';

import {
  BoxSelect,
  RefreshCw,
  RotateCcw,
  ScanSearch,
  Search,
  SlidersHorizontal,
} from 'lucide-react';
import { NavLink } from 'react-router-dom';

import type {
  AssetAvailability,
  AssetMediaKind,
  AssetSort,
  SourceFolder,
  SourceSummary,
} from '@/api/contracts/asset';
import type { TagSummary } from '@/api/contracts/tag';

export type GalleryDensity = 'comfortable' | 'compact';

const AVAILABILITY_OPTIONS: { value: AssetAvailability; label: string }[] = [
  { value: 'available', label: '可用' },
  { value: 'missing', label: '文件缺失' },
  { value: 'unreadable', label: '不可读取' },
  { value: 'unsupported', label: '格式不支持' },
];

const MEDIA_FORMAT_GROUPS = [
  { id: 'jpeg', label: 'JPEG', mediaKind: 'image', mediaTypes: ['public.jpeg'] },
  { id: 'png', label: 'PNG', mediaKind: 'image', mediaTypes: ['public.png'] },
  {
    id: 'heic',
    label: 'HEIC / HEIF',
    mediaKind: 'image',
    mediaTypes: ['public.heic', 'public.heif'],
  },
  { id: 'tiff', label: 'TIFF', mediaKind: 'image', mediaTypes: ['public.tiff'] },
  { id: 'webp', label: 'WebP', mediaKind: 'image', mediaTypes: ['org.webmproject.webp'] },
  {
    id: 'jpeg2000',
    label: 'JPEG 2000',
    mediaKind: 'image',
    mediaTypes: ['public.jpeg-2000'],
  },
  { id: 'gif', label: 'GIF', mediaKind: 'image', mediaTypes: ['com.compuserve.gif'] },
  { id: 'svg', label: 'SVG', mediaKind: 'image', mediaTypes: ['public.svg-image'] },
  {
    id: 'pdfai',
    label: 'PDF / AI',
    mediaKind: 'image',
    mediaTypes: ['com.adobe.pdf', 'com.adobe.illustrator.ai-image'],
  },
  {
    id: 'raw',
    label: 'RAW',
    mediaKind: 'image',
    mediaTypes: ['com.fuji.raw-image', 'com.adobe.raw-image', 'public.camera-raw-image'],
  },
  {
    id: 'mp4mov',
    label: 'MP4 / MOV',
    mediaKind: 'video',
    mediaTypes: ['public.mpeg-4', 'com.apple.quicktime-movie'],
  },
] as const;

export type GalleryFilters = {
  searchText: string;
  sort: AssetSort;
  mediaKind: AssetMediaKind | null;
  tagConditions: { tagID: string; decision: 'accepted' | 'rejected' }[];
  tagMatchMode: 'all' | 'any';
  tagPresence: 'any' | 'tagged' | 'untagged';
  availabilities: AssetAvailability[];
  mediaTypes: string[];
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
  const [draftTagID, setDraftTagID] = useState('');
  const [draftTagDecision, setDraftTagDecision] = useState<'accepted' | 'rejected'>('accepted');
  const [filtersOpen, setFiltersOpen] = useState(false);
  const selectedSource = sources.find((source) => source.id === filters.sourceID) ?? null;
  const folderSegments = filters.folderRelativePath?.split('/').filter(Boolean) ?? [];
  const querySuffix = searchQuery ? `?${searchQuery}` : '';
  const selectedFormatGroupCount = MEDIA_FORMAT_GROUPS.filter((group) =>
    group.mediaTypes.every((type) => filters.mediaTypes.includes(type)),
  ).length;
  const activeAdvancedFilterCount =
    filters.tagConditions.length +
    filters.availabilities.length +
    selectedFormatGroupCount +
    Number(filters.tagPresence !== 'any');

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
        <div className="gallery-filter-drawer-heading">
          <div>
            <span>筛选工作台</span>
            <strong>缩小你的视觉范围</strong>
          </div>
          <button
            aria-label="关闭筛选"
            className="icon-button gallery-filter-close"
            onClick={() => setFiltersOpen(false)}
            type="button"
          >
            ×
          </button>
        </div>
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
            onChange={(event) => {
              const mediaKind = event.target.value ? (event.target.value as AssetMediaKind) : null;
              const permittedTypes = new Set<string>(
                MEDIA_FORMAT_GROUPS.filter(
                  (group) => mediaKind === null || group.mediaKind === mediaKind,
                ).flatMap((group) => [...group.mediaTypes]),
              );
              onApply({
                ...filters,
                mediaKind,
                mediaTypes: filters.mediaTypes.filter((type) => permittedTypes.has(type)),
              });
            }}
            value={filters.mediaKind ?? ''}
          >
            <option value="">全部</option>
            <option value="image">照片</option>
            <option value="video">视频</option>
          </select>
        </label>

        <label className="compact-field">
          <span>标签范围</span>
          <select
            onChange={(event) => {
              const tagPresence = event.target.value as GalleryFilters['tagPresence'];
              onApply({
                ...filters,
                tagPresence,
                tagConditions: tagPresence === 'any' ? filters.tagConditions : [],
                tagMatchMode: tagPresence === 'any' ? filters.tagMatchMode : 'all',
              });
            }}
            value={filters.tagPresence}
          >
            <option value="any">全部照片</option>
            <option value="tagged">已有标签</option>
            <option value="untagged">无标签</option>
          </select>
        </label>

        {filters.tagPresence === 'any' ? (
          <fieldset className="gallery-tag-filter">
            <legend>标签判断</legend>
            {filters.tagConditions.length > 0 ? (
              <div className="gallery-filter-chips" aria-label="已选标签条件">
                {filters.tagConditions.map((condition) => {
                  const tagName =
                    tags.find((candidate) => candidate.id === condition.tagID)?.displayName ??
                    '未知标签';
                  const decisionName = condition.decision === 'accepted' ? '已确认' : '已拒绝';
                  return (
                    <span className="gallery-filter-chip" key={condition.tagID}>
                      {tagName} · {decisionName}
                      <button
                        aria-label={`移除标签条件 ${tagName} ${decisionName}`}
                        onClick={() =>
                          onApply({
                            ...filters,
                            tagConditions: filters.tagConditions.filter(
                              (candidate) => candidate.tagID !== condition.tagID,
                            ),
                          })
                        }
                        type="button"
                      >
                        ×
                      </button>
                    </span>
                  );
                })}
              </div>
            ) : null}
            <div className="gallery-tag-builder">
              <label>
                <span>添加标签</span>
                <select onChange={(event) => setDraftTagID(event.target.value)} value={draftTagID}>
                  <option value="">选择标签…</option>
                  {tags.map((tag) => (
                    <option key={tag.id} value={tag.id}>
                      {tag.displayName}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                <span>标签决定</span>
                <select
                  onChange={(event) =>
                    setDraftTagDecision(event.target.value as 'accepted' | 'rejected')
                  }
                  value={draftTagDecision}
                >
                  <option value="accepted">已确认</option>
                  <option value="rejected">已拒绝</option>
                </select>
              </label>
              <button
                className="button"
                disabled={!draftTagID}
                onClick={() => {
                  if (!draftTagID) return;
                  onApply({
                    ...filters,
                    tagConditions: [
                      ...filters.tagConditions.filter(
                        (condition) => condition.tagID !== draftTagID,
                      ),
                      { tagID: draftTagID, decision: draftTagDecision },
                    ],
                  });
                  setDraftTagID('');
                }}
                type="button"
              >
                添加标签条件
              </button>
            </div>
            {filters.tagConditions.length > 1 ? (
              <div aria-label="标签条件关系" className="gallery-tag-relation" role="radiogroup">
                <label>
                  <input
                    checked={filters.tagMatchMode === 'all'}
                    name="gallery-tag-match"
                    onChange={() => onApply({ ...filters, tagMatchMode: 'all' })}
                    type="radio"
                  />
                  满足全部
                </label>
                <label>
                  <input
                    checked={filters.tagMatchMode === 'any'}
                    name="gallery-tag-match"
                    onChange={() => onApply({ ...filters, tagMatchMode: 'any' })}
                    type="radio"
                  />
                  满足任一
                </label>
              </div>
            ) : null}
          </fieldset>
        ) : null}

        <fieldset className="gallery-choice-filter">
          <legend>可用状态</legend>
          <div className="gallery-filter-options">
            {AVAILABILITY_OPTIONS.map((option) => (
              <label key={option.value}>
                <input
                  checked={filters.availabilities.includes(option.value)}
                  onChange={(event) =>
                    onApply({
                      ...filters,
                      availabilities: event.target.checked
                        ? [...filters.availabilities, option.value]
                        : filters.availabilities.filter((value) => value !== option.value),
                    })
                  }
                  type="checkbox"
                />
                {option.label}
              </label>
            ))}
          </div>
        </fieldset>

        <fieldset className="gallery-choice-filter gallery-format-filter">
          <legend>文件格式</legend>
          <div className="gallery-filter-options">
            {MEDIA_FORMAT_GROUPS.filter(
              (group) => filters.mediaKind === null || group.mediaKind === filters.mediaKind,
            ).map((group) => {
              const selected = group.mediaTypes.every((type) => filters.mediaTypes.includes(type));
              return (
                <label key={group.id}>
                  <input
                    checked={selected}
                    onChange={(event) => {
                      const groupTypes = new Set<string>(group.mediaTypes);
                      onApply({
                        ...filters,
                        mediaTypes: event.target.checked
                          ? [...new Set([...filters.mediaTypes, ...group.mediaTypes])]
                          : filters.mediaTypes.filter((type) => !groupTypes.has(type)),
                      });
                    }}
                    type="checkbox"
                  />
                  {group.label}
                </label>
              );
            })}
          </div>
        </fieldset>

        <label className="compact-field">
          <span>排序</span>
          <select
            onChange={(event) => onApply({ ...filters, sort: event.target.value as AssetSort })}
            value={filters.sort}
          >
            <option value="newest">最新优先</option>
            <option value="oldest">最早优先</option>
            <option value="embeddedTimeNewest">媒体内嵌时间：新到旧</option>
            <option value="embeddedTimeOldest">媒体内嵌时间：旧到新</option>
            <option value="fileModifiedNewest">文件修改时间：新到旧</option>
            <option value="fileModifiedOldest">文件修改时间：旧到新</option>
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

        {activeAdvancedFilterCount > 0 ? (
          <button
            aria-label={`清除 ${String(activeAdvancedFilterCount)} 个筛选条件`}
            className="button gallery-clear-filters"
            onClick={() =>
              onApply({
                ...filters,
                tagConditions: [],
                tagMatchMode: 'all',
                tagPresence: 'any',
                availabilities: [],
                mediaTypes: [],
              })
            }
            type="button"
          >
            <RotateCcw aria-hidden="true" size={14} /> 清除筛选
            <span aria-hidden="true">{activeAdvancedFilterCount}</span>
          </button>
        ) : null}

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
