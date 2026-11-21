import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { encodeBasicCredentials } from '../utils/Base64Tools';
import {
  backupDirectoryUrl,
  backupFilePrefix,
  backupIndexFileName,
  backupManifestFileName,
  buildRemoteBackupFileUrl,
  buildRemoteFileUrl,
  buildVersionedBackupFileName,
  buildWebDavBackupIndex,
  isZipBackupFileName,
  mergeWebDavBackupEntries,
  parseWebDavBackupIndex,
  parseWebDavBackupManifest,
  WebDavBackupEntry,
} from '../utils/BackupModel';

const USER_AGENT: string = 'QYFM-HarmonyOS/1.0.47';

export interface WebDavConfig {
  baseUrl: string;
  user: string;
  password: string;
  fileName: string;
}

interface WebDavHeaders {
  'Authorization'?: string;
  'Content-Type': string;
  'User-Agent': string;
  'Overwrite': string;
}

interface WebDavTextResponse {
  code: number;
  text: string;
}

interface WebDavIndexData {
  backups: WebDavBackupEntry[];
}

interface BackupMetadata {
  exportedAt?: string;
  appVersion?: string;
  stations?: object[];
}

function buildHeaders(config: WebDavConfig, contentType: string): WebDavHeaders {
  if (config.user.length > 0) {
    return {
      'Authorization': `Basic ${encodeBasicCredentials(config.user, config.password)}`,
      'Content-Type': contentType,
      'User-Agent': USER_AGENT,
      'Overwrite': 'T'
    };
  }
  return {
    'Content-Type': contentType,
    'User-Agent': USER_AGENT,
    'Overwrite': 'T'
  };
}

function describeHttpFailure(code: number, prefix: string): Error {
  let hint = '';
  if (code === 401 || code === 403) {
    hint = '（账号或密码错误，或账号没有读写权限）';
  } else if (code === 404) {
    hint = '（备份文件或目录不存在）';
  } else if (code === 409) {
    hint = '（上级目录不存在或路径冲突）';
  } else if (code === 405) {
    hint = '（目标不是可写的 WebDAV 地址）';
  }
  return new Error(`${prefix}：HTTP ${code}${hint}`);
}

function legacyManifestUrl(config: WebDavConfig): string {
  return buildRemoteFileUrl(config.baseUrl, backupManifestFileName(config.fileName));
}

function indexUrl(config: WebDavConfig): string {
  return buildRemoteFileUrl(config.baseUrl, backupIndexFileName(config.fileName));
}

function legacyFileName(config: WebDavConfig): string {
  return `${backupFilePrefix(config.fileName)}.json`;
}

export class WebDavBackupService {
  async testConnection(config: WebDavConfig): Promise<void> {
    const directory = backupDirectoryUrl(config.baseUrl);
    const request = http.createHttp();
    try {
      const response = await request.request(directory, {
        method: http.RequestMethod.OPTIONS,
        header: buildHeaders(config, 'application/json'),
        connectTimeout: 20000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING
      });
      if (response.responseCode < 200 || response.responseCode >= 400) {
        throw describeHttpFailure(response.responseCode, 'WebDAV 连接失败');
      }
    } finally {
      request.destroy();
    }
  }

  async uploadBackup(
    config: WebDavConfig,
    data: ArrayBuffer,
    exportedAt: string,
    stationCount: number,
    appVersion: string
  ): Promise<WebDavBackupEntry> {
    const fileName = buildVersionedBackupFileName(config.fileName, new Date(exportedAt));
    const entry: WebDavBackupEntry = {
      fileName: fileName,
      exportedAt: exportedAt,
      stationCount: stationCount,
      appVersion: appVersion
    };
    await this.putBinary(
      config,
      buildRemoteFileUrl(config.baseUrl, fileName),
      data,
      '云端 ZIP 备份失败'
    );
    const manifest = await this.loadManifest(config);
    const entries = mergeWebDavBackupEntries(manifest.backups, entry);
    await this.putText(
      config,
      indexUrl(config),
      buildWebDavBackupIndex(entries),
      '云端版本索引更新失败',
      'text/plain; charset=utf-8'
    );
    return entry;
  }

  async listBackups(config: WebDavConfig): Promise<WebDavBackupEntry[]> {
    const manifest = await this.loadManifest(config);
    if (manifest.backups.length > 0) {
      return manifest.backups;
    }
    const legacy = await this.getText(
      config,
      buildRemoteFileUrl(config.baseUrl, legacyFileName(config)),
      true
    );
    if (legacy.code === 200 && legacy.text.length > 0) {
      const metadata = JSON.parse(legacy.text) as BackupMetadata;
      return [{
        fileName: legacyFileName(config),
        exportedAt: typeof metadata.exportedAt === 'string' ? metadata.exportedAt : '',
        stationCount: Array.isArray(metadata.stations) ? metadata.stations.length : 0,
        appVersion: typeof metadata.appVersion === 'string' ? metadata.appVersion : ''
      }];
    }
    return [];
  }

  async downloadBackup(config: WebDavConfig, fileName: string): Promise<string> {
    const response = await this.getText(config, buildRemoteFileUrl(config.baseUrl, fileName), false);
    if (response.code !== 200) {
      throw describeHttpFailure(response.code, '云端恢复失败');
    }
    if (response.text.length === 0) {
      throw new Error('WebDAV 返回的备份内容为空');
    }
    return response.text;
  }

  async fileExists(config: WebDavConfig, fileName: string): Promise<boolean> {
    if (!isZipBackupFileName(fileName)) {
      return false;
    }
    const request = http.createHttp();
    try {
      const response = await request.request(buildRemoteBackupFileUrl(config.baseUrl, fileName), {
        method: http.RequestMethod.HEAD,
        header: buildHeaders(config, 'application/zip'),
        connectTimeout: 20000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING
      });
      return response.responseCode === 200 || response.responseCode === 204;
    } catch (error) {
      return false;
    } finally {
      request.destroy();
    }
  }

  async downloadBackupBytes(config: WebDavConfig, fileName: string): Promise<ArrayBuffer> {
    if (!isZipBackupFileName(fileName)) {
      throw new Error('WebDAV ZIP 备份文件名无效');
    }
    const request = http.createHttp();
    try {
      const response = await request.request(buildRemoteBackupFileUrl(config.baseUrl, fileName), {
        method: http.RequestMethod.GET,
        header: buildHeaders(config, 'application/zip'),
        connectTimeout: 20000,
        readTimeout: 120000,
        maxLimit: 100 * 1024 * 1024,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      if (response.responseCode !== 200) {
        throw describeHttpFailure(response.responseCode, '云端 ZIP 恢复失败');
      }
      if (!(response.result instanceof ArrayBuffer)) {
        throw new Error('WebDAV 返回的 ZIP 内容无效');
      }
      return response.result;
    } catch (error) {
      const businessError = error as BusinessError;
      throw new Error(businessError.message ?? 'WebDAV ZIP 下载失败');
    } finally {
      request.destroy();
    }
  }

  private async loadManifest(config: WebDavConfig): Promise<WebDavIndexData> {
    const indexResponse = await this.getText(config, indexUrl(config), true);
    if (indexResponse.code === 200) {
      return { backups: parseWebDavBackupIndex(indexResponse.text) };
    }
    if (indexResponse.code !== 404) {
      throw describeHttpFailure(indexResponse.code, '读取云端版本索引失败');
    }
    const legacyResponse = await this.getText(config, legacyManifestUrl(config), true);
    if (legacyResponse.code === 404) {
      return { backups: [] };
    }
    if (legacyResponse.code !== 200) {
      throw describeHttpFailure(legacyResponse.code, '读取旧版云端版本列表失败');
    }
    return { backups: parseWebDavBackupManifest(legacyResponse.text).backups };
  }

  private async putText(
    config: WebDavConfig,
    url: string,
    text: string,
    failurePrefix: string,
    contentType: string = 'text/plain; charset=utf-8'
  ): Promise<void> {
    const request = http.createHttp();
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.PUT,
        header: buildHeaders(config, contentType),
        extraData: text,
        connectTimeout: 20000,
        readTimeout: 120000,
        maxLimit: 50 * 1024 * 1024,
        expectDataType: http.HttpDataType.STRING
      });
      if (response.responseCode !== 200 && response.responseCode !== 201 && response.responseCode !== 204) {
        throw describeHttpFailure(response.responseCode, failurePrefix);
      }
    } catch (error) {
      const businessError = error as BusinessError;
      throw new Error(businessError.message ?? `${failurePrefix}：未知错误`);
    } finally {
      request.destroy();
    }
  }

  private async putBinary(
    config: WebDavConfig,
    url: string,
    data: ArrayBuffer,
    failurePrefix: string
  ): Promise<void> {
    const request = http.createHttp();
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.PUT,
        header: buildHeaders(config, 'application/zip'),
        extraData: data,
        connectTimeout: 20000,
        readTimeout: 120000,
        maxLimit: 100 * 1024 * 1024,
        expectDataType: http.HttpDataType.STRING
      });
      if (response.responseCode !== 200 && response.responseCode !== 201 && response.responseCode !== 204) {
        throw describeHttpFailure(response.responseCode, failurePrefix);
      }
    } catch (error) {
      const businessError = error as BusinessError;
      throw new Error(businessError.message ?? `${failurePrefix}：未知错误`);
    } finally {
      request.destroy();
    }
  }

  private async getText(
    config: WebDavConfig,
    url: string,
    allowNotFound: boolean
  ): Promise<WebDavTextResponse> {
    const request = http.createHttp();
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: buildHeaders(config, 'application/json'),
        connectTimeout: 20000,
        readTimeout: 120000,
        maxLimit: 50 * 1024 * 1024,
        expectDataType: http.HttpDataType.STRING
      });
      if (!allowNotFound && response.responseCode !== 200) {
        throw describeHttpFailure(response.responseCode, '云端恢复失败');
      }
      return {
        code: response.responseCode,
        text: typeof response.result === 'string' ? response.result : ''
      };
    } catch (error) {
      if (allowNotFound) {
        const businessError = error as BusinessError;
        const message = businessError.message ?? '';
        if (message.includes('404')) {
          return { code: 404, text: '' };
        }
      }
      const businessError = error as BusinessError;
      throw new Error(businessError.message ?? 'WebDAV 下载失败：未知错误');
    } finally {
      request.destroy();
    }
  }
}
