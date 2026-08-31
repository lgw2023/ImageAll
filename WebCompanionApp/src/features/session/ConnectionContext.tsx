import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';

import { useQuery, useQueryClient } from '@tanstack/react-query';

import { fetchCapabilities } from '@/api/capabilities';
import { remoteEventSchema, type RemoteEvent } from '@/api/contracts/events';
import { APIError, errorMessage } from '@/api/errors';
import { restoreSession } from '@/api/session';

import { useSession } from './SessionContext';

type ConnectionPhase = 'connecting' | 'online' | 'offline' | 'retrying';

type ConnectionContextValue = {
  phase: ConnectionPhase;
  detail: string;
  retry: () => void;
};

const reconnectDelays = [1_000, 2_000, 4_000, 8_000, 16_000, 30_000] as const;
const ConnectionContext = createContext<ConnectionContextValue | null>(null);

function websocketURL(): string {
  const url = new URL('/v1/events/websocket', window.location.href);
  url.protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return url.toString();
}

async function invalidateForEvent(
  event: RemoteEvent,
  invalidate: (queryKey: readonly unknown[]) => Promise<void>,
) {
  const keys: readonly (readonly unknown[])[] =
    event.kind === 'sourcesChanged'
      ? [['source-management'], ['storage-maintenance'], ['assets'], ['gallery-overview']]
      : event.kind === 'tagsChanged'
        ? [['tags'], ['tag-groups'], ['tag-selection'], ['review-overview'], ['review-queue']]
        : event.kind === 'assetsChanged'
          ? [
              ['assets'],
              ['asset'],
              ['gallery-overview'],
              ['world-map'],
              ['world-map-selection'],
              ['slimming-workspace'],
            ]
          : event.kind === 'jobsChanged'
            ? [
                ['jobs'],
                ['training-activities'],
                ['embedding-preparation'],
                ['sample-suggestions'],
                ['library-suggestions'],
                ['tag-library-suggestions'],
                ['slimming-setup'],
                ['slimming-workspace'],
              ]
            : event.kind === 'reviewChanged'
              ? [['review-overview'], ['review-queue'], ['assets'], ['tag-selection']]
              : [];
  await Promise.all(keys.map(invalidate));
  if (event.kind !== 'ping') await invalidate(['workspace-notice']);
}

export function ConnectionProvider({ children }: { children: ReactNode }) {
  const session = useSession();
  const queryClient = useQueryClient();
  const [phase, setPhase] = useState<ConnectionPhase>('connecting');
  const [detail, setDetail] = useState('正在确认 Host 状态。');
  const [retryGeneration, setRetryGeneration] = useState(0);
  const reconnectAttempt = useRef(0);
  const capabilities = useQuery({
    queryKey: ['capabilities'],
    queryFn: ({ signal }) => fetchCapabilities(signal),
    staleTime: 60_000,
    retry: 1,
  });

  const retry = useCallback(() => {
    reconnectAttempt.current = 0;
    setPhase('retrying');
    setDetail('正在重新连接，同时保留当前工作区。');
    setRetryGeneration((value) => value + 1);
    void capabilities.refetch();
  }, [capabilities]);

  useEffect(() => {
    const setBrowserOffline = () => {
      setPhase('offline');
      setDetail('浏览器当前离线；工作区状态已保留。');
    };
    const setBrowserOnline = () => retry();
    window.addEventListener('offline', setBrowserOffline);
    window.addEventListener('online', setBrowserOnline);
    return () => {
      window.removeEventListener('offline', setBrowserOffline);
      window.removeEventListener('online', setBrowserOnline);
    };
  }, [retry]);

  useEffect(() => {
    if (capabilities.isPending) return;
    if (capabilities.isError) {
      let disposed = false;
      queueMicrotask(() => {
        if (disposed) return;
        setPhase('offline');
        setDetail(errorMessage(capabilities.error));
        if (capabilities.error instanceof APIError && capabilities.error.status === 401) {
          session.expire('会话已过期，请重新连接。');
        }
      });
      return () => {
        disposed = true;
      };
    }

    const invalidate = async (queryKey: readonly unknown[]) => {
      await queryClient.invalidateQueries({ queryKey });
    };
    const supportsEvents = capabilities.data.capabilities.includes('events');
    if (session.session?.authMode !== 'pairedDevice' || !supportsEvents) {
      queueMicrotask(() => {
        setPhase('online');
        setDetail(
          session.session?.authMode === 'account'
            ? '账户会话已连接；通过安全轮询同步 Host。'
            : 'Host 已连接。',
        );
      });
      const poll = window.setInterval(() => {
        void restoreSession()
          .then(async () => {
            setPhase('online');
            await Promise.all([
              invalidate(['capabilities']),
              invalidate(['workspace-notice']),
              invalidate(['jobs']),
            ]);
          })
          .catch((error: unknown) => {
            setPhase('offline');
            setDetail(errorMessage(error));
            if (error instanceof APIError && error.status === 401) {
              session.expire('会话已过期，请重新连接。');
            }
          });
      }, 10_000);
      return () => window.clearInterval(poll);
    }

    let disposed = false;
    let socket: WebSocket | null = null;
    let reconnectTimer: number | null = null;
    const connect = () => {
      if (disposed || !navigator.onLine) return;
      const attempt = reconnectAttempt.current;
      setPhase(attempt === 0 ? 'connecting' : 'retrying');
      setDetail(attempt === 0 ? '正在建立实时连接。' : '正在重新连接，同时保留当前工作区。');
      socket = new WebSocket(websocketURL());
      socket.addEventListener('open', () => {
        reconnectAttempt.current = 0;
        setPhase('online');
        setDetail('实时连接正常。');
      });
      socket.addEventListener('message', (message) => {
        if (typeof message.data !== 'string') return;
        try {
          const parsed = remoteEventSchema.safeParse(JSON.parse(message.data) as unknown);
          if (parsed.success) void invalidateForEvent(parsed.data, invalidate);
        } catch {
          // Ignore malformed event frames; the next valid Host projection remains authoritative.
        }
      });
      socket.addEventListener('close', () => {
        if (disposed) return;
        const delay =
          reconnectDelays[Math.min(reconnectAttempt.current, reconnectDelays.length - 1)];
        reconnectAttempt.current += 1;
        setPhase('retrying');
        setDetail(`实时连接中断；将在 ${String((delay ?? 30_000) / 1000)} 秒内重试。`);
        reconnectTimer = window.setTimeout(connect, delay ?? 30_000);
      });
      socket.addEventListener('error', () => socket?.close());
    };
    connect();
    const projectionPoll = window.setInterval(() => {
      void Promise.all([invalidate(['workspace-notice']), invalidate(['jobs'])]);
    }, 15_000);
    return () => {
      disposed = true;
      if (reconnectTimer !== null) window.clearTimeout(reconnectTimer);
      window.clearInterval(projectionPoll);
      socket?.close();
    };
  }, [
    capabilities.data,
    capabilities.error,
    capabilities.isError,
    capabilities.isPending,
    queryClient,
    retryGeneration,
    session,
  ]);

  const value = useMemo<ConnectionContextValue>(
    () => ({ phase, detail, retry }),
    [detail, phase, retry],
  );
  return <ConnectionContext.Provider value={value}>{children}</ConnectionContext.Provider>;
}

export function useConnection(): ConnectionContextValue {
  const value = useContext(ConnectionContext);
  if (!value) throw new Error('useConnection must be used within ConnectionProvider');
  return value;
}
