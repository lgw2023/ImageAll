/** Business domain first; controlled compatibility with Hosts that only sent UTI/MIME. */
export function resolvedMediaKind(
  asset: { mediaType: string; mediaKind?: 'image' | 'video' | null | undefined } | null | undefined,
): 'image' | 'video' | null {
  if (!asset) return null;
  if (asset.mediaKind) return asset.mediaKind;
  const value = asset.mediaType.trim().toLowerCase();
  if (value.startsWith('video/')) return 'video';
  if (value.startsWith('image/')) return 'image';
  if (
    [
      'public.movie',
      'public.video',
      'public.mpeg-4',
      'com.apple.quicktime-movie',
      'public.mpeg',
      'public.avi',
      'public.3gpp',
      'public.3gpp2',
    ].includes(value)
  )
    return 'video';
  if (
    [
      'public.image',
      'public.jpeg',
      'public.png',
      'public.heic',
      'public.heif',
      'public.tiff',
      'com.compuserve.gif',
      'com.microsoft.bmp',
      'org.webmproject.webp',
    ].includes(value)
  )
    return 'image';
  return null;
}
