import type { ReactNode } from 'react';

import { AuthenticationScreen } from './AuthenticationScreen';
import { useSession } from './SessionContext';

export function SessionGate({ children }: { children: ReactNode }) {
  const session = useSession();
  if (session.phase === 'booting') {
    return (
      <main className="boot-screen" id="main-content" aria-busy="true">
        <div className="boot-mark" aria-hidden="true" />
        <h1>正在连接 ImageAll</h1>
        <p>正在恢复安全会话…</p>
      </main>
    );
  }
  if (session.phase === 'unauthenticated') {
    return (
      <AuthenticationScreen
        initialMessage={session.initialMessage}
        onLogin={session.login}
        onPair={session.pair}
      />
    );
  }
  return children;
}
