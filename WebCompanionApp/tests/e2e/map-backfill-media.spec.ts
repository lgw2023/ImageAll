import { expect, test } from '@playwright/test';
import { installSyntheticAuthenticatedHost } from './syntheticHost';

for (const supportsBackfill of [true, false]) {
  test(`video backfill ${supportsBackfill ? 'preserves scope and supports cancellation' : 'is blocked on a legacy Host'}`, async ({
    page,
  }) => {
    await installSyntheticAuthenticatedHost(page);
    await page.route('**/v1/capabilities', (route) =>
      route.fulfill({
        json: {
          protocolVersion: 2,
          hostAppVersion: 'Synthetic Host',
          minimumClientProtocolVersion: 1,
          capabilities: ['assetPages', 'assetDetail', 'tags'],
          usesTLS: false,
          listenPort: 4173,
          hostID: null,
          certificateFingerprintSHA256: null,
          worldMapMediaScopeVersion: 1,
          ...(supportsBackfill ? { worldMapBackfillMediaScopeVersion: 1 } : {}),
        },
      }),
    );
    const scopes: string[] = [];
    const commands: { mediaScope: string; action: string }[] = [];
    let row = {
      sourceID: 'aaaaaaaa-1111-4222-8333-aaaaaaaaaaaa',
      sourceKind: 'folder',
      sourceDisplayName: 'Synthetic video folder',
      sourceState: 'active',
      phase: 'ready',
      totalPhotoCount: 7,
      inspectedPhotoCount: 2,
      locatedPhotoCount: 1,
      activeJobID: null,
      scanProgress: null,
      canStart: true,
      canCancel: false,
      mediaScope: 'videos',
    };
    await page.route('**/v1/world-map/location-backfill?*', (route) => {
      scopes.push(new URL(route.request().url()).searchParams.get('mediaScope') ?? 'photos');
      return route.fulfill({ json: [row] });
    });
    await page.route('**/v1/world-map/location-backfill/requests', (route) => {
      const body = route.request().postDataJSON() as {
        operationID: string;
        mediaScope: string;
        action: string;
      };
      commands.push(body);
      row = {
        ...row,
        phase: body.action === 'start' ? 'running' : 'cancelled',
        canStart: body.action !== 'start',
        canCancel: body.action === 'start',
      };
      return route.fulfill({
        status: 202,
        json: { operationID: body.operationID, snapshot: row, replayed: false },
      });
    });
    await page.goto('map?mediaScope=videos');
    if (!supportsBackfill) {
      await expect(
        page.getByText('此 Mac 尚不支持视频位置回填；请更新 Mac，或切回照片地图。'),
      ).toBeVisible();
      expect(scopes).toEqual([]);
      await expect(page.getByRole('button', { name: '开始回填' })).toHaveCount(0);
      return;
    }
    await expect(page.getByRole('heading', { name: '视频位置回填' })).toBeVisible();
    await expect(page.getByText('范围内已检查 2 / 7 项 · 已定位 1')).toBeVisible();
    expect(scopes).toEqual(['videos']);
    expect(commands).toEqual([]);
    await page.getByRole('button', { name: '开始回填' }).click();
    await expect(page.getByText('Mac 已接收位置回填任务。')).toBeVisible();
    await page.getByRole('button', { name: '取消', exact: true }).click();
    await expect(page.getByText('Mac 已接收取消请求。')).toBeVisible();
    expect(commands.map(({ mediaScope, action }) => ({ mediaScope, action }))).toEqual([
      { mediaScope: 'videos', action: 'start' },
      { mediaScope: 'videos', action: 'cancel' },
    ]);
  });
}
