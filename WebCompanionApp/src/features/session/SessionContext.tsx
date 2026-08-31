import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react';

import type { SessionStatus } from '@/api/contracts/session';
import { APIError } from '@/api/errors';
import { loginWithAccount, logoutSession, pairBrowser, restoreSession } from '@/api/session';

type SessionPhase = 'booting' | 'authenticated' | 'unauthenticated';

type SessionContextValue = {
  phase: SessionPhase;
  session: SessionStatus | null;
  initialMessage: string;
  pair: (token: string, deviceName: string) => Promise<void>;
  login: (username: string, password: string) => Promise<void>;
  logout: () => Promise<void>;
};

const SessionContext = createContext<SessionContextValue | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [phase, setPhase] = useState<SessionPhase>('booting');
  const [session, setSession] = useState<SessionStatus | null>(null);
  const [initialMessage, setInitialMessage] = useState('');

  useEffect(() => {
    const controller = new AbortController();
    void restoreSession()
      .then((status) => {
        if (controller.signal.aborted) return;
        setSession(status);
        setPhase('authenticated');
      })
      .catch((error: unknown) => {
        if (controller.signal.aborted) return;
        setSession(null);
        setInitialMessage(
          error instanceof APIError && error.status === 0 ? '暂时无法连接 Mac。' : '',
        );
        setPhase('unauthenticated');
      });
    return () => controller.abort();
  }, []);

  const pair = useCallback(async (token: string, deviceName: string) => {
    const status = await pairBrowser({ pairingToken: token, deviceName });
    setSession(status);
    setPhase('authenticated');
  }, []);

  const login = useCallback(async (username: string, password: string) => {
    const status = await loginWithAccount(username, password);
    setSession(status);
    setPhase('authenticated');
  }, []);

  const logout = useCallback(async () => {
    await logoutSession();
    setSession(null);
    setPhase('unauthenticated');
  }, []);

  const value = useMemo<SessionContextValue>(
    () => ({ phase, session, initialMessage, pair, login, logout }),
    [initialMessage, login, logout, pair, phase, session],
  );

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function useSession(): SessionContextValue {
  const value = useContext(SessionContext);
  if (!value) throw new Error('useSession must be used within SessionProvider');
  return value;
}
