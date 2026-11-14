export const WEBDAV_MANIFEST_SCHEMA_VERSION: number = 1;
export const WEBDAV_MANIFEST_SUFFIX: string = '-versions.json';
export const WEBDAV_BACKUP_LIMIT: number = 100;

export interface WebDavBackupEntry {
  fileName: string;
  exportedAt: string;
  stationCount: number;
  appVersion: string;
}

export interface WebDavBackupManifest {
  schemaVersion: number;
  backups: WebDavBackupEntry[];
}

export interface BackupStationRef {
  id: string;
}

export function backupDirectoryUrl(baseUrl: string): string {
  const normalized = baseUrl.trim().replaceAll('\r', '').replaceAll('\n', '');
  if (normalized.length === 0) {
    throw new Error('请先填写 WebDAV 地址');
  }
  if (!normalized.toLowerCase().endsWith('.json')) {
    return normalized.replace(/\/+$/, '');
  }
  const slash = normalized.lastIndexOf('/');
  return slash < 0 ? '' : normalized.substring(0, slash);
}

export function buildRemoteFileUrl(directoryUrl: string, fileName: string): string {
  const directory = backupDirectoryUrl(directoryUrl);
  if (directory.length === 0) {
    throw new Error('WebDAV 地址必须包含目录');
  }
  return `${directory.replace(/\/+$/, '')}/${encodeURIComponent(fileName)}`;
}

export function isZipBackupFileName(fileName: string): boolean {
  const normalized = fileName.trim().replaceAll('\\', '/');
  return normalized.toLowerCase().endsWith('.zip') &&
    !normalized.startsWith('/') &&
    !normalized.includes('..') &&
    !normalized.includes('/');
}

export function buildRemoteBackupFileUrl(baseUrl: string, fileName: string): string {
  const normalized = baseUrl.trim().replaceAll('\r', '').replaceAll('\n', '');
  if (normalized.toLowerCase().endsWith('.zip')) {
    return normalized;
  }
  if (!isZipBackupFileName(fileName)) {
    throw new Error('WebDAV ZIP 文件名必须以 .zip 结尾');
  }
  return buildRemoteFileUrl(normalized, fileName.trim());
}

export function backupFilePrefix(configuredFileName: string): string {
  const normalized = configuredFileName.trim().replaceAll('\\', '/');
  if (normalized.length === 0 || normalized.startsWith('/') || normalized.includes('..') ||
    normalized.includes('/')) {
    throw new Error('WebDAV 文件名不能为空，不能包含路径或 ..');
  }
  const withoutExtension = normalized.replace(/\.[^.]+$/, '');
  return withoutExtension.length > 0 ? withoutExtension : 'qyfm-backup';
}

export function backupManifestFileName(configuredFileName: string): string {
  return `${backupFilePrefix(configuredFileName)}${WEBDAV_MANIFEST_SUFFIX}`;
}

function twoDigits(value: number): string {
  return value.toString().padStart(2, '0');
}

export function formatBackupTimestamp(date: Date): string {
  const datePart = `${date.getUTCFullYear()}${twoDigits(date.getUTCMonth() + 1)}${twoDigits(date.getUTCDate())}`;
  const timePart = `${twoDigits(date.getUTCHours())}${twoDigits(date.getUTCMinutes())}${twoDigits(date.getUTCSeconds())}`;
  const milliseconds = date.getUTCMilliseconds().toString().padStart(3, '0');
  return `${datePart}-${timePart}-${milliseconds}`;
}

export function buildVersionedBackupFileName(configuredFileName: string, date: Date): string {
  return `${backupFilePrefix(configuredFileName)}-${formatBackupTimestamp(date)}.json`;
}

function isValidBackupEntry(entry: WebDavBackupEntry): boolean {
  return typeof entry.fileName === 'string' &&
    entry.fileName.endsWith('.json') &&
    !entry.fileName.startsWith('/') &&
    !entry.fileName.includes('..') &&
    !entry.fileName.includes('/') &&
    typeof entry.exportedAt === 'string' &&
    entry.exportedAt.length > 0;
}

export function parseWebDavBackupManifest(text: string): WebDavBackupManifest {
  let parsed: WebDavBackupManifest;
  try {
    parsed = JSON.parse(text) as WebDavBackupManifest;
  } catch (error) {
    throw new Error('无法解析 WebDAV 备份版本列表');
  }
  if (parsed.schemaVersion !== WEBDAV_MANIFEST_SCHEMA_VERSION || !Array.isArray(parsed.backups)) {
    throw new Error('不是受支持的 WebDAV 备份版本列表');
  }
  return {
    schemaVersion: WEBDAV_MANIFEST_SCHEMA_VERSION,
    backups: parsed.backups.filter((entry: WebDavBackupEntry) => isValidBackupEntry(entry))
  };
}

export function serializeWebDavBackupManifest(entries: WebDavBackupEntry[]): string {
  const manifest: WebDavBackupManifest = {
    schemaVersion: WEBDAV_MANIFEST_SCHEMA_VERSION,
    backups: entries
  };
  return JSON.stringify(manifest);
}

export function mergeWebDavBackupEntries(
  entries: WebDavBackupEntry[],
  next: WebDavBackupEntry
): WebDavBackupEntry[] {
  const unique = new Map<string, WebDavBackupEntry>();
  entries.forEach((entry: WebDavBackupEntry) => {
    if (isValidBackupEntry(entry)) {
      unique.set(entry.fileName, entry);
    }
  });
  unique.set(next.fileName, next);
  return Array.from(unique.values())
    .sort((left: WebDavBackupEntry, right: WebDavBackupEntry) => right.exportedAt.localeCompare(left.exportedAt))
    .slice(0, WEBDAV_BACKUP_LIMIT);
}

export function orderStationsByBackup<T extends BackupStationRef>(
  stations: T[],
  stationOrder: string[]
): T[] {
  const unique = new Map<string, T>();
  stations.forEach((station: T) => {
    if (station.id.length > 0) {
      unique.set(station.id, station);
    }
  });
  const ordered: T[] = [];
  const included = new Set<string>();
  stationOrder.forEach((id: string) => {
    const station = unique.get(id);
    if (station !== undefined && !included.has(id)) {
      included.add(id);
      ordered.push(station);
    }
  });
  unique.forEach((station: T, id: string) => {
    if (!included.has(id)) {
      ordered.push(station);
    }
  });
  return ordered;
}
