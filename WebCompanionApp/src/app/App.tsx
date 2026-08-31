import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import {
  Activity,
  Archive,
  Database,
  FolderKanban,
  Map,
  Settings,
  WandSparkles,
} from 'lucide-react';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';

import { SessionGate } from '@/features/session/SessionGate';
import { SessionProvider } from '@/features/session/SessionContext';
import { GalleryRoute } from '@/features/gallery/GalleryRoute';
import { GalleryOverviewRoute } from '@/features/overview/GalleryOverviewRoute';
import { ReviewRoute } from '@/features/review/ReviewRoute';
import { TagLibraryRoute } from '@/features/tags/TagLibraryRoute';

import { AppErrorBoundary } from './AppErrorBoundary';
import { AppShell } from './AppShell';
import { PlaceholderRoute } from './PlaceholderRoute';
import { ThemeProvider } from './ThemeProvider';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      gcTime: 5 * 60_000,
      retry: 1,
      refetchOnWindowFocus: false,
    },
    mutations: { retry: false },
  },
});

const placeholders = [
  {
    path: 'map',
    eyebrow: '工具',
    title: '世界地图',
    description: '按位置浏览图库，完成位置回填和地方标签。',
    icon: Map,
  },
  {
    path: 'training',
    eyebrow: '工具',
    title: '训练',
    description: '配置个人模型、准备嵌入并跟踪训练活动。',
    icon: WandSparkles,
  },
  {
    path: 'slimming',
    eyebrow: '工具',
    title: '图库精简',
    description: '审查重复和相似项，在 Mac 确认后安全释放空间。',
    icon: Archive,
  },
  {
    path: 'sources',
    eyebrow: '管理',
    title: '照片来源',
    description: '查看 Apple Photos 和文件夹来源的同步与扫描状态。',
    icon: FolderKanban,
  },
  {
    path: 'storage',
    eyebrow: '管理',
    title: '存储与维护',
    description: '查看应用存储健康并向 Mac 发起受控维护。',
    icon: Database,
  },
  {
    path: 'activity',
    eyebrow: '管理',
    title: '活动',
    description: '跟踪训练、维护、建议和精简任务。',
    icon: Activity,
  },
  {
    path: 'settings',
    eyebrow: '管理',
    title: '设置',
    description: '管理通用选项、连接与已配对设备。',
    icon: Settings,
  },
] as const;

export function App() {
  return (
    <AppErrorBoundary>
      <ThemeProvider>
        <QueryClientProvider client={queryClient}>
          <SessionProvider>
            <SessionGate>
              <BrowserRouter basename="/web-v2">
                <Routes>
                  <Route element={<AppShell />}>
                    <Route index element={<Navigate replace to="gallery" />} />
                    <Route path="gallery" element={<GalleryRoute />} />
                    <Route path="gallery/favorites" element={<GalleryRoute />} />
                    <Route path="gallery/overview" element={<GalleryOverviewRoute />} />
                    <Route path="assets/:assetId" element={<GalleryRoute />} />
                    <Route path="review" element={<ReviewRoute />} />
                    <Route path="review/queue" element={<ReviewRoute />} />
                    <Route path="tags" element={<TagLibraryRoute />} />
                    {placeholders.map((route) => (
                      <Route
                        key={route.path}
                        path={route.path}
                        element={<PlaceholderRoute {...route} />}
                      />
                    ))}
                    <Route path="*" element={<Navigate replace to="gallery" />} />
                  </Route>
                </Routes>
              </BrowserRouter>
            </SessionGate>
          </SessionProvider>
        </QueryClientProvider>
      </ThemeProvider>
    </AppErrorBoundary>
  );
}
