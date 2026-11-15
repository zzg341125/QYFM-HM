const MAX_SESSION_ARTWORK_LENGTH: number = 40960;

export function safeSessionArtwork(iconUrl: string): string {
  const value = iconUrl.trim();
  if (value.length === 0 || value.length > MAX_SESSION_ARTWORK_LENGTH) {
    return '';
  }
  const lower = value.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://') ||
    lower.startsWith('file://') || lower.startsWith('content://')) {
    return value;
  }
  return '';
}
