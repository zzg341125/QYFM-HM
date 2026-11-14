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

export function selectInstallAsset(assets: UpdateAsset[]): UpdateAsset | undefined {
  const installAssets = assets.filter((asset: UpdateAsset) =>
    (asset.name.toLowerCase().endsWith('.app') ||
      asset.name.toLowerCase().endsWith('.app.zip') ||
      asset.name.toLowerCase().endsWith('.hap')) &&
    asset.browser_download_url.toLowerCase().startsWith('https://') &&
    !asset.name.toLowerCase().includes('unsigned'));
  const appZipAssets = installAssets.filter((asset: UpdateAsset) =>
    asset.name.toLowerCase().endsWith('.app.zip'));
  const appAssets = installAssets.filter((asset: UpdateAsset) =>
    asset.name.toLowerCase().endsWith('.app') && !asset.name.toLowerCase().endsWith('.app.zip'));
  const hapAssets = installAssets.filter((asset: UpdateAsset) => asset.name.toLowerCase().endsWith('.hap'));
  const signedAppZip = appZipAssets.find((asset: UpdateAsset) =>
    asset.name.toLowerCase().includes('signed'));
  if (signedAppZip !== undefined) {
    return signedAppZip;
  }
  if (appZipAssets.length > 0) {
    return appZipAssets[0];
  }
  const signedApp = appAssets.find((asset: UpdateAsset) => asset.name.toLowerCase().includes('signed'));
  if (signedApp !== undefined) {
    return signedApp;
  }
  if (appAssets.length > 0) {
    return appAssets[0];
  }
  const signedHap = hapAssets.find((asset: UpdateAsset) => asset.name.toLowerCase().includes('signed'));
  return signedHap ?? (hapAssets.length > 0 ? hapAssets[0] : undefined);
}

export function selectHapAsset(assets: UpdateAsset[]): UpdateAsset | undefined {
  return selectInstallAsset(assets);
}

export function installUtdForFileName(fileName: string): string {
  const lower = fileName.toLowerCase();
  if (lower.endsWith('.app')) {
    return 'openharmony.package';
  }
  if (lower.endsWith('.hap')) {
    return 'openharmony.hap';
  }
  return '';
}

export function buildUpdateFileName(tag: string, assetName: string): string {
  const rawName = assetName.replaceAll('\\', '/').split('/').pop() ?? '';
  const safeName = rawName
    .trim()
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');
  if (safeName.toLowerCase().endsWith('.hap') ||
    safeName.toLowerCase().endsWith('.app') ||
    safeName.toLowerCase().endsWith('.app.zip')) {
    return safeName;
  }
  const safeTag = tag.replace(/[^A-Za-z0-9._-]+/g, '-');
  return `QYFM-HM-${safeTag}-signed.hap`;
}
