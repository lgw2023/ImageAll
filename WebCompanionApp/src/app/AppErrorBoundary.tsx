import { Component, type ErrorInfo, type ReactNode } from 'react';

type Props = { children: ReactNode };
type State = { error: Error | null };

export class AppErrorBoundary extends Component<Props, State> {
  override state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  override componentDidCatch(error: Error, info: ErrorInfo): void {
    console.error('Web Companion render failure', error, info.componentStack);
  }

  override render(): ReactNode {
    if (!this.state.error) return this.props.children;
    return (
      <main className="fatal-error" id="main-content">
        <p className="eyebrow">界面遇到问题</p>
        <h1>无法显示当前工作区</h1>
        <p>这不会修改 Mac 上的照片或数据库。可重新加载界面后继续。</p>
        <button className="button button-primary" onClick={() => location.reload()} type="button">
          重新加载
        </button>
      </main>
    );
  }
}
