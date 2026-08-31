import { useCallback, useEffect, useRef, useState } from 'react';

const FAILURE_WINDOW_MS = 2_000;
const FAILURE_THRESHOLD = 3;
const INITIAL_RETRY_MS = 800;
const MAX_RETRY_MS = 10_000;

export function useThumbnailRecovery() {
  const [generation, setGeneration] = useState(0);
  const [recovering, setRecovering] = useState(false);
  const failures = useRef<{ at: number; url: string }[]>([]);
  const retryTimer = useRef<number | null>(null);
  const retryDelay = useRef(INITIAL_RETRY_MS);

  const clearTimer = useCallback(() => {
    if (retryTimer.current !== null) window.clearTimeout(retryTimer.current);
    retryTimer.current = null;
  }, []);

  const scheduleProbe = useCallback((url: string) => {
    function schedule() {
      if (retryTimer.current !== null) return;
      setRecovering(true);
      retryTimer.current = window.setTimeout(() => {
        retryTimer.current = null;
        const probe = new Image();
        probe.onload = () => {
          failures.current = [];
          retryDelay.current = INITIAL_RETRY_MS;
          setRecovering(false);
          setGeneration((value) => value + 1);
        };
        probe.onerror = () => {
          retryDelay.current = Math.min(MAX_RETRY_MS, retryDelay.current * 2);
          schedule();
        };
        const separator = url.includes('?') ? '&' : '?';
        probe.src = `${url}${separator}recoveryProbe=${String(Date.now())}`;
      }, retryDelay.current);
    }
    schedule();
  }, []);

  const reportFailure = useCallback(
    (url: string) => {
      const now = Date.now();
      failures.current = failures.current.filter(
        (failure) => now - failure.at <= FAILURE_WINDOW_MS,
      );
      failures.current.push({ at: now, url });
      if (failures.current.length >= FAILURE_THRESHOLD) scheduleProbe(url);
    },
    [scheduleProbe],
  );

  useEffect(() => clearTimer, [clearTimer]);

  return { generation, recovering, reportFailure };
}
