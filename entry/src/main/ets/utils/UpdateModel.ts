export interface UpdateAsset {
  name: string;
  browser_download_url: string;
  size: number;
}

function parseVersion(value: string): number[] {
  return value.replace(/^harmony-v/i, '').replace(/^v/i, '').split('.').map((part: string) => {
    const match = part.match(/^\d+/);
    return match === null ? 0 : Number(match[0]);
  });
}

export function isNewerVersion(remote: string, current: string): boolean {
  const remoteParts = parseVersion(remote);
  const currentParts = parseVersion(current);
  const count = Math.max(remoteParts.length, currentParts.length);
  for (let index = 0; index < count; index++) {
    const remotePart = remoteParts[index] ?? 0;
    const currentPart = currentParts[index] ?? 0;
    if (remotePart > currentPart) {
      return true;
    }
    if (remotePart < currentPart) {
      return false;
    }
  }
  return false;
}

export function selectHapAsset(assets: UpdateAsset[]): UpdateAsset | undefined {
  const hapAssets = assets.filter((asset: UpdateAsset) =>
    asset.name.toLowerCase().endsWith('.hap') &&
    asset.browser_download_url.toLowerCase().startsWith('https://') &&
    !asset.name.toLowerCase().includes('unsigned'));
  const signed = hapAssets.find((asset: UpdateAsset) =>
    asset.name.toLowerCase().includes('signed'));
  return signed ?? (hapAssets.length > 0 ? hapAssets[0] : undefined);
}

export function buildUpdateFileName(tag: string, assetName: string): string {
  const rawName = assetName.replaceAll('\\', '/').split('/').pop() ?? '';
  const safeName = rawName
    .trim()
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');
  if (safeName.toLowerCase().endsWith('.hap')) {
    return safeName;
  }
  const safeTag = tag.replace(/[^A-Za-z0-9._-]+/g, '-');
  return `QYFM-HM-${safeTag}-signed.hap`;
}
