import { useState, type ComponentType } from 'react';

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
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
import { NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom';

import { fetchCapabilities } from '@/api/capabilities';
import { errorMessage } from '@/api/errors';
import {
  dismissWorkspaceNotice,
  fetchWorkspaceNotice,
  performWorkspaceNoticeAction,
} from '@/api/workspaceNotice';
import { useConnection } from '@/features/session/ConnectionContext';
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
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const theme = useTheme();
  const session = useSession();
  const connection = useConnection();
  const capabilities = useQuery({
    queryKey: ['capabilities'],
    queryFn: ({ signal }) => fetchCapabilities(signal),
    staleTime: 60_000,
    retry: 1,
  });
  const noticesSupported = capabilities.data?.capabilities.includes('workspaceNotices') ?? false;
  const notice = useQuery({
    queryKey: ['workspace-notice'],
    queryFn: ({ signal }) => fetchWorkspaceNotice(signal),
    enabled: noticesSupported,
    refetchInterval: connection.phase === 'online' ? 15_000 : false,
  });
  const dismissNotice = useMutation({
    mutationFn: dismissWorkspaceNotice,
    onSuccess: (next) => queryClient.setQueryData(['workspace-notice'], next),
  });
  const runNoticeAction = useMutation({
    mutationFn: ({ noticeID, actionID }: { noticeID: string; actionID: string }) =>
      performWorkspaceNoticeAction(noticeID, actionID),
    onSuccess: (response, variables) => {
      queryClient.setQueryData(['workspace-notice'], response.notice);
      const action = notice.data?.actions.find((candidate) => candidate.id === variables.actionID);
      if (response.performed && action?.kind === 'openRecycleBin') {
        void navigate('/slimming?section=recycle');
      }
      if (response.performed) {
        void Promise.all([
          queryClient.invalidateQueries({ queryKey: ['assets'] }),
          queryClient.invalidateQueries({ queryKey: ['tags'] }),
          queryClient.invalidateQueries({ queryKey: ['slimming-recycle'] }),
        ]);
      }
    },
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
            data-state={connection.phase === 'online' ? 'online' : 'offline'}
          >
            <span className="connection-dot" aria-hidden="true" />
            {connection.phase === 'online'
              ? '已连接'
              : connection.phase === 'offline'
                ? 'Mac 离线'
                : connection.phase === 'retrying'
                  ? '正在重连'
                  : '正在连接'}
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
        <a className="legacy-link" href="/legacy/">
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
        {connection.phase === 'offline' || connection.phase === 'retrying' ? (
          <div className="connection-banner" role="status">
            <div>
              <strong>
                {connection.phase === 'offline' ? '与 Mac 的连接已中断' : '正在恢复实时连接'}
              </strong>
              <span>{connection.detail}</span>
            </div>
            <button className="button" onClick={connection.retry} type="button">
              重试
            </button>
          </div>
        ) : null}
        {notice.data ? (
          <section
            aria-live={notice.data.severity === 'warning' ? 'assertive' : 'polite'}
            className="workspace-notice"
            data-severity={notice.data.severity}
          >
            <p>{notice.data.message}</p>
            <div className="workspace-notice-actions">
              {notice.data.actions.map((action) => (
                <button
                  className="button"
                  disabled={runNoticeAction.isPending}
                  key={action.id}
                  onClick={() =>
                    runNoticeAction.mutate({ noticeID: notice.data!.id, actionID: action.id })
                  }
                  type="button"
                >
                  {action.title}
                </button>
              ))}
              <button
                aria-label="关闭工作区通知"
                className="icon-button"
                disabled={dismissNotice.isPending}
                onClick={() => dismissNotice.mutate(notice.data!.id)}
                type="button"
              >
                <X aria-hidden="true" size={16} />
              </button>
            </div>
          </section>
        ) : null}
        {dismissNotice.isError || runNoticeAction.isError ? (
          <p className="form-error" role="alert">
            {errorMessage(dismissNotice.error ?? runNoticeAction.error)}
          </p>
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
