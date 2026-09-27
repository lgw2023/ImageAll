import { describe, expect, it } from 'vitest';
import { assetDetailSchema, assetSummarySchema } from './asset';
import { resolvedMediaKind } from './mediaKind';

const payload = {
  id: '11111111-1111-4111-8111-111111111111',
  assetID: '11111111-1111-4111-8111-111111111111',
  sourceID: '22222222-2222-4222-8222-222222222222',
  sourceName: 'Synthetic',
  availability: 'available',
  contentRevision: 1,
  acceptedTagCount: 0,
  rejectedTagCount: 0,
  tags: [],
};

describe('production UTI and explicit media domain', () => {
  it.each([
    ['public.mpeg-4', 'video'],
    ['com.apple.quicktime-movie', 'video'],
    ['video/mp4', 'video'],
    ['public.heic', 'image'],
    ['image/jpeg', 'image'],
    ['vendor.unknown', null],
    ['application/octet-stream', null],
  ])('decodes an old Host format %s', (mediaType, expected) => {
    expect(resolvedMediaKind(assetSummarySchema.parse({ ...payload, mediaType }))).toBe(expected);
    expect(resolvedMediaKind(assetDetailSchema.parse({ ...payload, mediaType }))).toBe(expected);
  });
  it('uses the explicit domain and rejects a future unknown domain', () => {
    expect(
      resolvedMediaKind(
        assetDetailSchema.parse({
          ...payload,
          mediaType: 'vendor.unknown',
          mediaKind: 'video',
        }),
      ),
    ).toBe('video');
    expect(
      assetSummarySchema.safeParse({
        ...payload,
        mediaType: 'public.jpeg',
        mediaKind: 'future-domain',
      }).success,
    ).toBe(false);
    expect(resolvedMediaKind(undefined)).toBeNull();
  });
});

it('preserves technical observations and keeps old Hosts unknown', () => {
  expect(
    assetDetailSchema.parse({ ...payload, mediaType: 'public.mpeg-4' }).videoTechnicalMetadata,
  ).toBeUndefined();
  const detail = assetDetailSchema.parse({
    ...payload,
    mediaType: 'public.mpeg-4',
    videoTechnicalMetadata: {
      codec: 'avc1',
      nominalFrameRate: 29.97,
      audioTrackCount: 0,
    },
  });
  expect(detail.videoTechnicalMetadata).toEqual({
    codec: 'avc1',
    nominalFrameRate: 29.97,
    audioTrackCount: 0,
    estimatedDataRate: null,
  });
});
