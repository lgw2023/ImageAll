import { useEffect, useRef, useState } from 'react';

import { ChevronDown, Images } from 'lucide-react';

import type { SourceSummary } from '@/api/contracts/asset';

type ReviewSourceScopeProps = {
  sources: SourceSummary[];
  sourceIDs: string[] | null;
  isPending: boolean;
  isError: boolean;
  onChange: (sourceIDs: string[] | null) => void;
};

function scopeLabel(sources: SourceSummary[], sourceIDs: string[] | null) {
  if (!sources.length) return '没有可用来源';
  if (sourceIDs === null) return `全部 ${String(sources.length)} 个来源`;
  if (!sourceIDs.length) return '未选择来源';
  const selectedNames = sources
    .filter((source) => sourceIDs.includes(source.id))
    .map((source) => source.displayName);
  const onlySelectedName = selectedNames[0];
  if (sourceIDs.length === 1 && onlySelectedName) return `仅 ${onlySelectedName}`;
  return `已选 ${String(sourceIDs.length)} 个来源`;
}

export function ReviewSourceScope({
  sources,
  sourceIDs,
  isPending,
  isError,
  onChange,
}: ReviewSourceScopeProps) {
  const [isOpen, setIsOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const selectedIDs = new Set(sourceIDs ?? sources.map((source) => source.id));
  const label = isPending
    ? '正在载入来源'
    : isError
      ? '来源载入失败'
      : scopeLabel(sources, sourceIDs);

  function toggle(sourceID: string) {
    const next = new Set(selectedIDs);
    if (next.has(sourceID)) next.delete(sourceID);
    else next.add(sourceID);
    const ordered = sources.filter((source) => next.has(source.id)).map((source) => source.id);
    onChange(ordered.length === sources.length ? null : ordered);
  }

  useEffect(() => {
    if (!isOpen) return;
    function closeOnOutsidePointer(event: PointerEvent) {
      if (!containerRef.current?.contains(event.target as Node)) setIsOpen(false);
    }
    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === 'Escape') setIsOpen(false);
    }
    window.addEventListener('pointerdown', closeOnOutsidePointer);
    window.addEventListener('keydown', closeOnEscape);
    return () => {
      window.removeEventListener('pointerdown', closeOnOutsidePointer);
      window.removeEventListener('keydown', closeOnEscape);
    };
  }, [isOpen]);

  return (
    <div className="review-source-scope" data-open={isOpen} ref={containerRef}>
      <button
        aria-expanded={isOpen}
        aria-haspopup="true"
        className="button review-source-trigger"
        onClick={() => setIsOpen((current) => !current)}
        type="button"
      >
        <Images aria-hidden="true" size={15} />
        <span>{label}</span>
        <ChevronDown aria-hidden="true" className="review-source-chevron" size={14} />
      </button>
      {isOpen ? (
        <div aria-label="审查来源范围" className="review-source-menu" role="group">
          <div className="review-source-menu-heading">
            <div>
              <strong>审查范围</strong>
              <span>总览与队列会同步更新</span>
            </div>
            <button
              className="text-button"
              disabled={isPending || isError || sourceIDs === null}
              onClick={() => onChange(null)}
              type="button"
            >
              全部来源
            </button>
          </div>
          {isError ? (
            <p className="review-source-error" role="alert">
              暂时无法载入来源列表。
            </p>
          ) : (
            <div className="review-source-options">
              {sources.map((source) => (
                <label key={source.id}>
                  <input
                    checked={selectedIDs.has(source.id)}
                    disabled={isPending}
                    onChange={() => toggle(source.id)}
                    type="checkbox"
                  />
                  <span>
                    <strong>{source.displayName}</strong>
                    <small>{source.kind === 'photos' ? '照片图库' : '文件夹'}</small>
                  </span>
                </label>
              ))}
            </div>
          )}
        </div>
      ) : null}
    </div>
  );
}
