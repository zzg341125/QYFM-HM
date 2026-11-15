export function migrateLegacyStreamUrl(url: string): string {
  const trimmed = url.trim();
  if (/^https:\/\/lhttp(?:-hw)?\.qtfm\.cn\//i.test(trimmed) ||
    /^https:\/\/lhttp\.qingting\.fm\//i.test(trimmed)) {
    return trimmed.replace(/^https:\/\//i, 'http://');
  }
  if (/^https?:\/\/radio\.936\.nz:8443\//i.test(trimmed)) {
    return trimmed.replace(
      /^https?:\/\/radio\.936\.nz:8443\//i,
      'http://radiolive.nz936.com:8443/'
    );
  }
  if (/^https?:\/\/video1\.getstreamhosting\.com:8292\/stream\?\.mp3(?:&.*)?$/i
    .test(trimmed)) {
    return trimmed.replace(
      /^https:\/\//i,
      'http://'
    );
  }
  return trimmed;
}
