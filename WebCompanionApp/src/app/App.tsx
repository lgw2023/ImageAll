import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';

import { SessionGate } from '@/features/session/SessionGate';
import { SessionProvider } from '@/features/session/SessionContext';
import { GalleryRoute } from '@/features/gallery/GalleryRoute';
import { WorldMapRoute } from '@/features/map/WorldMapRoute';
import { ActivityRoute } from '@/features/management/ActivityRoute';
import { SettingsRoute } from '@/features/management/SettingsRoute';
import { SourcesRoute } from '@/features/management/SourcesRoute';
import { StorageRoute } from '@/features/management/StorageRoute';
import { GalleryOverviewRoute } from '@/features/overview/GalleryOverviewRoute';
import { ReviewRoute } from '@/features/review/ReviewRoute';
import { TagLibraryRoute } from '@/features/tags/TagLibraryRoute';
import { TrainingRoute } from '@/features/training/TrainingRoute';
import { SlimmingRoute } from '@/features/slimming/SlimmingRoute';

import { AppErrorBoundary } from './AppErrorBoundary';
import { AppShell } from './AppShell';
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
              </BrowserRouter>
            </SessionGate>
          </SessionProvider>
        </QueryClientProvider>
      </ThemeProvider>
    </AppErrorBoundary>
  );
}
