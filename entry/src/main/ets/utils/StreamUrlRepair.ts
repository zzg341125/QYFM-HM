export function migrateLegacyStreamUrl(url: string): string {
  const trimmed = url.trim();
  if (/^https?:\/\/(?:lhttp\.)?(?:qingting\.fm|qtfm\.cn)\/live\/4915\/64k\.mp3(?:[?#].*)?$/i
    .test(trimmed)) {
    return 'https://ls.qingting.fm/live/4915.m3u8?bitrate=64';
  }
  if (/^https?:\/\/radio\.936\.nz:8443\//i.test(trimmed)) {
    return trimmed.replace(
      /^https?:\/\/radio\.936\.nz:8443\//i,
      'http://radiolive.nz936.com:8443/'
    );
  }
  return trimmed;
}
