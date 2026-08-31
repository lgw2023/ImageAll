import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { lazy, Suspense } from 'react';

import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';

import { SessionGate } from '@/features/session/SessionGate';
import { SessionProvider } from '@/features/session/SessionContext';
import { ConnectionProvider } from '@/features/session/ConnectionContext';

import { AppErrorBoundary } from './AppErrorBoundary';
import { AppShell } from './AppShell';
import { ThemeProvider } from './ThemeProvider';

const GalleryRoute = lazy(() =>
  import('@/features/gallery/GalleryRoute').then((module) => ({ default: module.GalleryRoute })),
);
const WorldMapRoute = lazy(() =>
  import('@/features/map/WorldMapRoute').then((module) => ({ default: module.WorldMapRoute })),
);
const ActivityRoute = lazy(() =>
  import('@/features/management/ActivityRoute').then((module) => ({
    default: module.ActivityRoute,
  })),
);
const SettingsRoute = lazy(() =>
  import('@/features/management/SettingsRoute').then((module) => ({
    default: module.SettingsRoute,
  })),
);
const SourcesRoute = lazy(() =>
  import('@/features/management/SourcesRoute').then((module) => ({ default: module.SourcesRoute })),
);
const StorageRoute = lazy(() =>
  import('@/features/management/StorageRoute').then((module) => ({ default: module.StorageRoute })),
);
const GalleryOverviewRoute = lazy(() =>
  import('@/features/overview/GalleryOverviewRoute').then((module) => ({
    default: module.GalleryOverviewRoute,
  })),
);
const ReviewRoute = lazy(() =>
  import('@/features/review/ReviewRoute').then((module) => ({ default: module.ReviewRoute })),
);
const TagLibraryRoute = lazy(() =>
  import('@/features/tags/TagLibraryRoute').then((module) => ({ default: module.TagLibraryRoute })),
);
const TrainingRoute = lazy(() =>
  import('@/features/training/TrainingRoute').then((module) => ({ default: module.TrainingRoute })),
);
const SlimmingRoute = lazy(() =>
  import('@/features/slimming/SlimmingRoute').then((module) => ({ default: module.SlimmingRoute })),
);

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

export function App() {
  return (
    <AppErrorBoundary>
      <ThemeProvider>
        <QueryClientProvider client={queryClient}>
          <SessionProvider>
            <SessionGate>
              <ConnectionProvider>
                <BrowserRouter basename="/web-v2">
                  <Suspense
                    fallback={
                      <div className="route-loading" role="status">
                        正在载入工作区…
                      </div>
                    }
                  >
                    <Routes>
                      <Route element={<AppShell />}>
                        <Route index element={<Navigate replace to="gallery" />} />
                        <Route path="gallery" element={<GalleryRoute />} />
                        <Route path="gallery/favorites" element={<GalleryRoute />} />
                        <Route path="gallery/overview" element={<GalleryOverviewRoute />} />
                        <Route path="assets/:assetId" element={<GalleryRoute />} />
                        <Route path="review" element={<ReviewRoute />} />
                        <Route path="review/queue" element={<ReviewRoute />} />
                        <Route path="map" element={<WorldMapRoute />} />
                        <Route path="tags" element={<TagLibraryRoute />} />
                        <Route path="sources" element={<SourcesRoute />} />
                        <Route path="storage" element={<StorageRoute />} />
                        <Route path="activity" element={<ActivityRoute />} />
                        <Route path="settings" element={<SettingsRoute />} />
                        <Route path="training" element={<TrainingRoute />} />
                        <Route path="slimming" element={<SlimmingRoute />} />
                        <Route path="*" element={<Navigate replace to="gallery" />} />
                      </Route>
                    </Routes>
                  </Suspense>
                </BrowserRouter>
              </ConnectionProvider>
            </SessionGate>
          </SessionProvider>
        </QueryClientProvider>
      </ThemeProvider>
    </AppErrorBoundary>
  );
}
