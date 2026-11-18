import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { zlib } from '@kit.BasicServicesKit';
import { AppSettings, Station } from '../models/Station';
import { decodeImageData } from '../utils/Base64Tools';
import {
  serializeQyfmBackupPlaylist,
  serializeQyfmBackupSettings
} from '../utils/QyfmBackupArchive';
import { buildVersionedBackupFileName } from '../utils/BackupModel';

const USER_AGENT: string = 'QYFM-HarmonyOS/1.0.45';
const MAX_ICON_BYTES: number = 2 * 1024 * 1024;

export interface QyfmBackupArchivePackage {
  path: string;
  fileName: string;
  data: ArrayBuffer;
  exportedAt: string;
  stationCount: number;
  appVersion: string;
}

class IconBytes {
  data: ArrayBuffer;
  extension: string;

  constructor(data: ArrayBuffer, extension: string) {
    this.data = data;
    this.extension = extension;
  }
}

export class BackupArchiveService {
  async createArchive(
    context: common.UIAbilityContext,
    stations: Station[],
    settings: AppSettings,
    configuredFileName: string
  ): Promise<QyfmBackupArchivePackage> {
    const now = new Date();
    const stamp = now.getTime().toString();
    const exportDir = `${context.cacheDir}/qyfm-export-${stamp}`;
    const logoDir = `${exportDir}/logos`;
    fileIo.mkdirSync(logoDir, true);
    const logoFiles = new Map<string, string>();
    for (let index = 0; index < stations.length; index++) {
      const station = stations[index];
      const icon = await this.loadIcon(station.iconUrl);
      if (icon === undefined) {
        if (station.iconUrl.length > 0) {
          logoFiles.set(station.id, station.iconUrl);
        }
        continue;
      }
      const fileName = `logo-${index + 1}.${icon.extension}`;
      const path = `${logoDir}/${fileName}`;
      this.writeBinary(path, icon.data);
      logoFiles.set(station.id, `logos/${fileName}`);
    }
    this.writeText(`${exportDir}/playlist.m3u`,
      serializeQyfmBackupPlaylist(stations, logoFiles));
    this.writeText(`${exportDir}/order.txt`,
      `${stations.map((station: Station): string => station.id).join('\n')}\n`);
    this.writeText(`${exportDir}/settings.properties`,
      serializeQyfmBackupSettings(settings));
    this.writeText(`${exportDir}/README.txt`,
      'QYFM 备份压缩包\n' +
      'playlist.m3u：电台、线路、当前线路、台标与播放顺序\n' +
      'order.txt：显式电台顺序\n' +
      'logos/：实际台标文件\n' +
      'settings.properties：非敏感设置（不含 WebDAV 密码）\n');
    const fileName = buildVersionedBackupFileName(configuredFileName, now);
    const path = `${context.cacheDir}/${fileName}`;
    await zlib.compressFile(exportDir, path, {
      level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION
    });
    return {
      path: path,
      fileName: fileName,
      data: this.readBinary(path),
      exportedAt: now.toISOString(),
      stationCount: stations.length,
      appVersion: '1.0.45'
    };
  }

  private async loadIcon(iconUrl: string): Promise<IconBytes | undefined> {
    if (iconUrl.startsWith('data:')) {
      const marker = iconUrl.indexOf(';base64,');
      if (marker < 0) {
        return undefined;
      }
      const mimeType = iconUrl.substring(5, marker);
      try {
        const data = decodeImageData(iconUrl.substring(marker + 8));
        return new IconBytes(data, this.extensionFromMime(mimeType));
      } catch (error) {
        console.info('本地台标解码失败，备份仅保留引用');
        return undefined;
      }
    }
    if (!iconUrl.toLowerCase().startsWith('http://') &&
      !iconUrl.toLowerCase().startsWith('https://')) {
      return undefined;
    }
    const request = http.createHttp();
    try {
      const response = await request.request(iconUrl, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': USER_AGENT,
          'Accept': 'image/*'
        },
        connectTimeout: 10000,
        readTimeout: 15000,
        maxLimit: MAX_ICON_BYTES,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: true
      });
      if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer) ||
        response.result.byteLength <= 0 || response.result.byteLength > MAX_ICON_BYTES) {
        return undefined;
      }
      return new IconBytes(response.result, this.extensionFromBytes(response.result, iconUrl));
    } catch (error) {
      const businessError = error as BusinessError;
      console.info(`台标下载失败，保留远程引用: ${businessError.message ?? '未知错误'}`);
      return undefined;
    } finally {
      request.destroy();
    }
  }

  private extensionFromMime(mimeType: string): string {
    if (mimeType.includes('png')) {
      return 'png';
    }
    if (mimeType.includes('webp')) {
      return 'webp';
    }
    if (mimeType.includes('gif')) {
      return 'gif';
    }
    return 'jpg';
  }

  private extensionFromBytes(data: ArrayBuffer, url: string): string {
    const bytes = new Uint8Array(data);
    if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e) {
      return 'png';
    }
    if (bytes.length >= 4 && bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) {
      return 'gif';
    }
    if (bytes.length >= 12 && bytes[0] === 0x52 && bytes[1] === 0x49 &&
      bytes[2] === 0x46 && bytes[3] === 0x46) {
      return 'webp';
    }
    const lower = url.toLowerCase();
    if (lower.includes('.png')) {
      return 'png';
    }
    if (lower.includes('.webp')) {
      return 'webp';
    }
    if (lower.includes('.gif')) {
      return 'gif';
    }
    return 'jpg';
  }

  private writeText(path: string, content: string): void {
    const file = fileIo.openSync(
      path,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
    );
    try {
      fileIo.writeSync(file.fd, content);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private writeBinary(path: string, content: ArrayBuffer): void {
    const file = fileIo.openSync(
      path,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
    );
    try {
      fileIo.writeSync(file.fd, content);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private readBinary(path: string): ArrayBuffer {
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const size = fileIo.statSync(file.fd).size;
      const buffer = new ArrayBuffer(size);
      const readLength = fileIo.readSync(file.fd, buffer);
      return readLength === size ? buffer : buffer.slice(0, readLength);
    } finally {
      fileIo.closeSync(file);
    }
  }
}
