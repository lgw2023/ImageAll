import type { AssetSort } from '@/api/contracts/asset';

export type VideoDuration = 'any' | 'underMinute' | 'oneToTenMinutes' | 'tenMinutesOrMore';
export type VideoOrientation = 'any' | 'landscape' | 'portrait' | 'square';
export function parseVideoDuration(value: string | null): VideoDuration {
  return value === 'underMinute' || value === 'oneToTenMinutes' || value === 'tenMinutesOrMore'
    ? value
    : 'any';
}
export function parseVideoOrientation(value: string | null): VideoOrientation {
  return value === 'landscape' || value === 'portrait' || value === 'square' ? value : 'any';
}
export function isDurationSort(sort: AssetSort): boolean {
  return sort === 'durationShortest' || sort === 'durationLongest';
}
export function requiresVideoQuery(sort: AssetSort): boolean {
  return isDurationSort(sort) || sort === 'fileSizeSmallest' || sort === 'fileSizeLargest';
}
