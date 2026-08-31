import { useState, type ComponentType } from 'react';

import { useQuery } from '@tanstack/react-query';
import {
  Activity,
  Archive,
  ChevronLeft,
  Database,
  FolderKanban,
  Images,
  Map as MapIcon,
  Menu,
  Moon,
  PanelRight,
  ScanSearch,
  Settings,
  SlidersHorizontal,
  Sun,
  Tags,
  WandSparkles,
  X,
} from 'lucide-react';
import { NavLink, Outlet, useLocation } from 'react-router-dom';

import { fetchCapabilities } from '@/api/capabilities';
import { errorMessage } from '@/api/errors';
import { useSession } from '@/features/session/SessionContext';

import { useTheme } from './ThemeProvider';

type NavigationItem = {
  to: string;
  label: string;
  icon: ComponentType<{ size?: number; 'aria-hidden'?: boolean }>;
};

const navigationGroups: { label: string; items: NavigationItem[] }[] = [
  {
    label: '照片',
    items: [
      { to: '/gallery', label: '图库', icon: Images },
      { to: '/review', label: '审查', icon: ScanSearch },
    ],
  },
  {
    label: '工具',
    items: [
      { to: '/map', label: '世界地图', icon: MapIcon },
      { to: '/training', label: '训练', icon: WandSparkles },
      { to: '/slimming', label: '图库精简', icon: Archive },
    ],
  },
  {
    label: '管理',
    items: [
      { to: '/sources', label: '照片来源', icon: FolderKanban },
      { to: '/storage', label: '存储与维护', icon: Database },
      { to: '/tags', label: '标签库', icon: Tags },
      { to: '/activity', label: '活动', icon: Activity },
      { to: '/settings', label: '设置', icon: Settings },
    ],
  },
];

const routeTitles = new Map(
  navigationGroups.flatMap((group) => group.items.map((item) => [item.to, item.label])),
);
routeTitles.set('/assets', '照片详情');

export function AppShell() {
  const [navigationOpen, setNavigationOpen] = useState(false);
  const [inspectorOpen, setInspectorOpen] = useState(
    () => window.matchMedia('(min-width: 900px)').matches,
  );
  const location = useLocation();
  const theme = useTheme();
  const session = useSession();
  const capabilities = useQuery({
    queryKey: ['capabilities'],
    queryFn: ({ signal }) => fetchCapabilities(signal),
    staleTime: 60_000,
    retry: 1,
  });
  const routePath = `/${location.pathname.split('/').find(Boolean) ?? 'gallery'}`;
  const title = routeTitles.get(routePath) ?? '工作区';

  return (
    <div className="app-frame">
      <a className="skip-link" href="#main-content">
        跳到主要内容
      </a>
      <header className="titlebar">
        <button
          aria-expanded={navigationOpen}
          aria-label={navigationOpen ? '关闭导航' : '打开导航'}
          className="icon-button navigation-toggle"
          onClick={() =>
            setNavigationOpen((value) => {
              const next = !value;
              if (next) setInspectorOpen(false);
              return next;
            })
          }
          type="button"
        >
          {navigationOpen ? <X size={18} /> : <Menu size={18} />}
        </button>
        <div className="titlebar-heading">
          <span className="titlebar-product">ImageAll</span>
          <span aria-hidden="true" className="titlebar-separator">
            /
          </span>
          <h1>{title}</h1>
        </div>
        <div className="titlebar-actions">
          <span
            className="connection-pill"
            data-state={capabilities.isError ? 'offline' : 'online'}
          >
            <span className="connection-dot" aria-hidden="true" />
            {capabilities.isPending ? '正在连接' : capabilities.isError ? 'Mac 离线' : '已连接'}
          </span>
          <button
            aria-label={theme.resolved === 'dark' ? '使用浅色主题' : '使用深色主题'}
            className="icon-button"
            onClick={() => theme.setMode(theme.resolved === 'dark' ? 'light' : 'dark')}
            type="button"
          >
            {theme.resolved === 'dark' ? <Sun size={18} /> : <Moon size={18} />}
          </button>
          <button
            aria-label={inspectorOpen ? '隐藏检视器' : '显示检视器'}
            className="icon-button inspector-toggle"
            onClick={() =>
              setInspectorOpen((value) => {
                const next = !value;
                if (next) setNavigationOpen(false);
                return next;
              })
            }
            type="button"
          >
            <PanelRight size={18} />
          </button>
        </div>
      </header>

      <aside className="sidebar" data-open={navigationOpen}>
        <div className="sidebar-brand">
          <div className="sidebar-brand-mark" aria-hidden="true">
            <Images size={18} />
          </div>
          <div>
            <strong>Web Companion</strong>
            <span>照片工作台</span>
          </div>
        </div>
        <nav aria-label="主导航">
          {navigationGroups.map((group) => (
            <section className="navigation-group" key={group.label}>
              <h2>{group.label}</h2>
              {group.items.map((item) => {
                const Icon = item.icon;
                return (
                  <NavLink
                    className={({ isActive }) => `navigation-link${isActive ? ' active' : ''}`}
                    key={item.to}
                    onClick={() => setNavigationOpen(false)}
                    to={item.to}
                  >
                    <Icon aria-hidden={true} size={17} />
                    <span>{item.label}</span>
                  </NavLink>
                );
              })}
            </section>
          ))}
        </nav>
        <a className="legacy-link" href="/">
          <ChevronLeft aria-hidden="true" size={15} /> 返回旧版
        </a>
      </aside>

      {navigationOpen ? (
        <button
          className="sidebar-scrim"
          aria-label="关闭导航"
          onClick={() => setNavigationOpen(false)}
          type="button"
        />
      ) : null}

      <main className="workspace" id="main-content" tabIndex={-1}>
        {capabilities.isError ? (
          <div className="connection-banner" role="status">
            <div>
              <strong>与 Mac 的连接已中断</strong>
              <span>{errorMessage(capabilities.error)}</span>
            </div>
            <button className="button" onClick={() => void capabilities.refetch()} type="button">
              重试
            </button>
          </div>
        ) : null}
        <Outlet />
      </main>

      <aside className="inspector" data-open={inspectorOpen} aria-label="检视器">
        <div className="inspector-header">
          <div>
            <p className="eyebrow">检视器</p>
            <h2>当前工作区</h2>
          </div>
          <button
            className="icon-button inspector-close"
            aria-label="关闭检视器"
            onClick={() => setInspectorOpen(false)}
            type="button"
          >
            <X size={17} />
          </button>
        </div>
        <dl className="metadata-list">
          <div>
            <dt>会话</dt>
            <dd>
              {session.session?.authMode === 'account'
                ? (session.session.username ?? '账户')
                : '已配对设备'}
            </dd>
          </div>
          <div>
            <dt>Host</dt>
            <dd>{capabilities.data?.hostAppVersion ?? '—'}</dd>
          </div>
          <div>
            <dt>协议</dt>
            <dd>{capabilities.data ? `v${String(capabilities.data.protocolVersion)}` : '—'}</dd>
          </div>
          <div>
            <dt>传输</dt>
            <dd>{capabilities.data?.usesTLS ? 'TLS' : '本机 loopback'}</dd>
          </div>
        </dl>
        <div className="inspector-note">
          <SlidersHorizontal size={17} aria-hidden="true" />
          <p>选中照片或工作项后，属性和上下文操作将显示在这里。</p>
        </div>
        <button
          className="button inspector-logout"
          onClick={() => void session.logout()}
          type="button"
        >
          退出当前会话
        </button>
      </aside>
    </div>
  );
}
