import { useQuery } from '@tanstack/react-query';
import { CalendarDays, Database, Heart, Images, Tags } from 'lucide-react';
import { Link } from 'react-router-dom';

import { errorMessage } from '@/api/errors';
import { fetchGalleryOverview } from '@/api/overview';

function count(value: number) {
  return value.toLocaleString('zh-CN');
}

export function GalleryOverviewRoute() {
  const overview = useQuery({
    queryKey: ['gallery-overview'],
    queryFn: ({ signal }) => fetchGalleryOverview(signal),
  });

  if (overview.isPending) {
    return (
      <div className="workspace-state" role="status">
        正在汇总图库…
      </div>
    );
  }
  if (overview.isError) {
    return (
      <div className="workspace-state workspace-state-error" role="alert">
        <strong>无法载入图库概览</strong>
        <p>{errorMessage(overview.error)}</p>
        <button className="button" onClick={() => void overview.refetch()} type="button">
          重试
        </button>
      </div>
    );
  }

  const total = overview.data.media.reduce((sum, item) => sum + item.totalCount, 0);
  const favoriteCount = overview.data.favorites?.reduce((sum, item) => sum + item.count, 0) ?? 0;

  return (
    <section className="domain-workspace overview-workspace" aria-labelledby="overview-title">
      <header className="domain-heading">
        <div>
          <p className="eyebrow">照片</p>
          <h2 id="overview-title">图库概览</h2>
          <p>所有统计均由当前 Mac Host 的目录快照计算。</p>
        </div>
        <Link className="button" to="/gallery">
          返回图库
        </Link>
      </header>

      <div className="metric-grid">
        <article className="metric-card">
          <Images aria-hidden="true" size={18} />
          <span>媒体总数</span>
          <strong>{count(total)}</strong>
        </article>
        <article className="metric-card">
          <Heart aria-hidden="true" size={18} />
          <span>收藏</span>
          <strong>{count(favoriteCount)}</strong>
        </article>
        <article className="metric-card">
          <Tags aria-hidden="true" size={18} />
          <span>已有正向标签</span>
          <strong>{count(overview.data.positiveLabeledAssetCount)}</strong>
        </article>
        <article className="metric-card">
          <Database aria-hidden="true" size={18} />
          <span>来源</span>
          <strong>{count(overview.data.sources.length)}</strong>
        </article>
      </div>

      <div className="overview-panels">
        <section className="data-panel" aria-labelledby="overview-media">
          <h3 id="overview-media">媒体与精确重复</h3>
          <div className="data-rows">
            {overview.data.media.map((item) => (
              <Link
                className="data-row"
                key={item.mediaKind}
                to={`/gallery?media=${item.mediaKind}`}
              >
                <span>{item.mediaKind === 'image' ? '照片' : '视频'}</span>
                <strong>{count(item.totalCount)}</strong>
                <small>{count(item.exactRedundantCount)} 项精确冗余</small>
              </Link>
            ))}
          </div>
        </section>

        <section className="data-panel" aria-labelledby="overview-sources">
          <h3 id="overview-sources">来源</h3>
          <div className="data-rows">
            {overview.data.sources.map((source) => (
              <div className="data-row" key={source.id}>
                <span>{source.displayName}</span>
                <strong>{count(source.imageCount + source.videoCount)}</strong>
                <small>{source.state === 'active' ? '可用' : '需要处理'}</small>
              </div>
            ))}
          </div>
        </section>

        <section className="data-panel" aria-labelledby="overview-tags">
          <h3 id="overview-tags">常用标签</h3>
          <div className="data-rows">
            {overview.data.positiveTags.slice(0, 10).map((tag) => (
              <Link className="data-row" key={tag.id} to={`/gallery?tag=${tag.id}`}>
                <span>{tag.displayName}</span>
                <strong>{count(tag.imageCount + tag.videoCount)}</strong>
                <small>进入筛选图库</small>
              </Link>
            ))}
          </div>
        </section>

        <section className="data-panel" aria-labelledby="overview-years">
          <h3 id="overview-years">
            <CalendarDays aria-hidden="true" size={17} /> 年份
          </h3>
          <div className="year-strip" role="list">
            {overview.data.years.slice(0, 12).map((year) => (
              <div key={year.year} role="listitem">
                <strong>{String(year.year)}</strong>
                <span>{count(year.imageCount + year.videoCount)}</span>
              </div>
            ))}
          </div>
          {overview.data.undatedCount > 0 ? (
            <p className="panel-note">另有 {count(overview.data.undatedCount)} 项没有日期。</p>
          ) : null}
        </section>
      </div>
    </section>
  );
}
