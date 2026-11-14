import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { encodeImageData } from '../utils/Base64Tools';
import { AndroidBackupLogoEntry } from '../utils/AndroidBackupModel';

const MAX_BACKUP_BYTES: number = 100 * 1024 * 1024;

export interface AndroidBackupArchiveFiles {
  manifestText: string;
  playlistText: string;
  playlistM3uText: string;
  settingsText: string;
  logos: AndroidBackupLogoEntry[];
}

export interface PickedBackup {
  isZip: boolean;
  text: string;
  archive: AndroidBackupArchiveFiles | undefined;
}

export class LocalFileService {
  async pickBackup(context: common.UIAbilityContext): Promise<PickedBackup | undefined> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['QYFM 备份|.json,.zip'];
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris = await documentPicker.select(options);
    if (uris.length === 0) {
      return undefined;
    }
    const uri = uris[0];
    try {
      const size = fileIo.statSync(uri).size;
      if (size <= 0) {
        throw new Error('备份文件为空');
      }
      if (size > MAX_BACKUP_BYTES) {
        throw new Error('备份文件不能超过 100 MB');
      }
      if (this.isZipFile(uri)) {
        return {
          isZip: true,
          text: '',
          archive: await this.readAndroidBackupZip(context, uri)
        };
      }
      return {
        isZip: false,
        text: fileIo.readTextSync(uri),
        archive: undefined
      };
    } catch (error) {
      const businessError = error as BusinessError;
      throw new Error(`读取备份失败：${businessError.message ?? '未知错误'}`);
    }
  }

  async pickText(context: common.UIAbilityContext, suffixFilter: string): Promise<string> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = [suffixFilter];
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris = await documentPicker.select(options);
    if (uris.length === 0) {
      return '';
    }
    try {
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      try {
        const size = fileIo.statSync(file.fd).size;
        if (size <= 0) {
          return '';
        }
        const buffer = new ArrayBuffer(size);
        const bytesRead = fileIo.readSync(file.fd, buffer);
        return util.TextDecoder.create('utf-8')
          .decodeToString(new Uint8Array(buffer.slice(0, bytesRead)));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (error) {
      const businessError = error as BusinessError;
      throw new Error(`读取文件失败：${businessError.message ?? '未知错误'}`);
    }
  }

  async saveText(context: common.UIAbilityContext, fileName: string, content: string): Promise<void> {
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [fileName];
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris = await documentPicker.save(options);
    if (uris.length === 0) {
      return;
    }
    try {
      const file = fileIo.openSync(
        uris[0],
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      try {
        fileIo.writeSync(file.fd, content);
      } finally {
        fileIo.closeSync(file);
      }
    } catch (error) {
      const businessError = error as BusinessError;
      throw new Error(`保存文件失败：${businessError.message ?? '未知错误'}`);
    }
  }

  private isZipFile(uri: string): boolean {
    const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const header = new ArrayBuffer(4);
      const length = fileIo.readSync(file.fd, header);
      if (length < 4) {
        return false;
      }
      const bytes = new Uint8Array(header);
      return bytes[0] === 0x50 && bytes[1] === 0x4b && bytes[2] === 0x03 && bytes[3] === 0x04;
    } finally {
      fileIo.closeSync(file);
    }
  }

  private async readAndroidBackupZip(
    context: common.UIAbilityContext,
    uri: string
  ): Promise<AndroidBackupArchiveFiles> {
    const stamp = Date.now().toString();
    const zipPath = `${context.cacheDir}/qyfm-android-backup-${stamp}.zip`;
    const outputDir = `${context.cacheDir}/qyfm-android-backup-${stamp}`;
    fileIo.copyFileSync(uri, zipPath);
    try {
      await zlib.decompressFile(zipPath, outputDir);
      return {
        manifestText: this.readOptionalText(`${outputDir}/manifest.json`),
        playlistText: this.readOptionalText(`${outputDir}/playlist.json`),
        playlistM3uText: this.readOptionalText(`${outputDir}/playlist.m3u`),
        settingsText: this.readOptionalText(`${outputDir}/settings.json`),
        logos: this.readBackupLogos(`${outputDir}/logos`)
      };
    } finally {
      try {
        fileIo.unlinkSync(zipPath);
      } catch (error) {
        console.error('清理临时备份压缩包失败');
      }
    }
  }

  private readOptionalText(path: string): string {
    try {
      return fileIo.readTextSync(path);
    } catch (error) {
      return '';
    }
  }

  private readBackupLogos(directory: string): AndroidBackupLogoEntry[] {
    const logos: AndroidBackupLogoEntry[] = [];
    try {
      fileIo.listFileSync(directory).forEach((name: string) => {
        const path = `${directory}/${name}`;
        const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
        try {
          const size = fileIo.statSync(file.fd).size;
          if (size <= 0 || size > 2 * 1024 * 1024) {
            return;
          }
          const buffer = new ArrayBuffer(size);
          const readLength = fileIo.readSync(file.fd, buffer);
          if (readLength !== size) {
            return;
          }
          const mimeType = this.iconMimeType(name);
          const dataUrl = encodeImageData(buffer, mimeType);
          logos.push({
            name: name,
            mimeType: mimeType,
            base64: dataUrl.substring(dataUrl.indexOf(',') + 1)
          });
        } finally {
          fileIo.closeSync(file);
        }
      });
    } catch (error) {
      console.info('备份中没有台标目录');
    }
    return logos;
  }

  private iconMimeType(name: string): string {
    const lower = name.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    return 'image/jpeg';
  }
}
