export function migrateLegacyStreamUrl(url: string): string {
  const trimmed = url.trim();
  if (/^https?:\/\/radio\.936\.nz:8443\//i.test(trimmed)) {
    return trimmed.replace(
      /^https?:\/\/radio\.936\.nz:8443\//i,
      'http://radiolive.nz936.com:8443/'
    );
  }
  return trimmed;
}
