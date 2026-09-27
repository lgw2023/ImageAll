import { useEffect, useRef, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { assetMediaURL, fetchAssetDetail } from '@/api/assets';
import { inspectVideoFailure } from '@/api/client';
import { resolvedMediaKind } from '@/api/contracts/mediaKind';

export function ReviewVideoPreview({ assetID, revision }: { assetID: string; revision: number }) {
  const player = useRef<HTMLVideoElement>(null);
  const [failed, setFailed] = useState(false);
  const [attempt, setAttempt] = useState(0);
  const detail = useQuery({
    queryKey: ['review-video-detail', assetID, revision],
    queryFn: ({ signal }) => fetchAssetDetail(assetID, signal),
  });
  const failure = useQuery({
    queryKey: ['review-video-failure', assetID, revision, attempt],
    enabled: failed,
    retry: false,
    queryFn: ({ signal }) => inspectVideoFailure(assetMediaURL(assetID, revision), signal),
  });
  useEffect(() => {
    const video = player.current;
    const pause = () => {
      if (document.hidden) video?.pause();
    };
    document.addEventListener('visibilitychange', pause);
    return () => {
      document.removeEventListener('visibilitychange', pause);
      video?.pause();
      video?.removeAttribute('src');
      video?.load();
    };
  }, [attempt, detail.data, failed]);
  if (detail.isPending) return <p role="status">正在读取视频详情…</p>;
  if (
    !detail.data ||
    resolvedMediaKind(detail.data) !== 'video' ||
    detail.data.contentRevision !== revision
  ) {
    return <p role="alert">视频详情不可用或内容已变化，请刷新审核队列。</p>;
  }
  if (failed)
    return (
      <div role="alert">
        <p>{failure.data ?? '当前无法播放视频，请检查 Mac 本地原件和格式后重试。'}</p>
        <button
          className="button"
          type="button"
          onClick={() => {
            setFailed(false);
            setAttempt((value) => value + 1);
          }}
        >
          重试播放
        </button>
      </div>
    );
  return (
    <video
      key={attempt}
      ref={player}
      aria-label="审核视频播放"
      controls
      preload="metadata"
      style={{ maxWidth: '100%', maxHeight: '65vh' }}
      src={assetMediaURL(assetID, revision)}
      onError={() => setFailed(true)}
    />
  );
}
