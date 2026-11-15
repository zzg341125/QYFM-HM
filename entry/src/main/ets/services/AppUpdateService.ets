import { common, Want, wantConstant } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { updateManager } from '@kit.AppGalleryKit';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import {
  buildUpdateFileName,
  installUtdForFileName,
  isNewerVersion,
  selectInstallAsset,
  UpdateAsset
} from '../utils/UpdateModel';
import {
  extractAppPackage,
  UpdateArchiveFileSystem
} from '../utils/UpdateArchiveModel';
import { buildFileManagerTarget } from '../utils/UpdateInstallerModel';

const GITHUB_RELEASES_URL: string =
  'https://api.github.com/repos/zzg341125/QYFM-HM/releases?per_page=30';
const CURRENT_VERSION: string = '1.0.17';

export interface NativeUpdateInfo {
  version: string;
  title: string;
  notes: string;
  pageUrl: string;
  downloadUrl: string;
  assetName: string;
  assetSize: number;
}

interface GitHubRelease {
  tag_name: string;
  name: string;
  body: string;
  html_url: string;
  prerelease: boolean;
  draft: boolean;
  assets?: UpdateAsset[];
}

class GitHubHeaders {
  'Accept': string = 'application/vnd.github+json';
  'User-Agent': string = 'QYFM-HarmonyOS';
}

export class AppUpdateService {
  async checkNativeRelease(): Promise<NativeUpdateInfo | undefined> {
    const request = http.createHttp();
    try {
      const response = await request.request(GITHUB_RELEASES_URL, {
        method: http.RequestMethod.GET,
        header: new GitHubHeaders(),
        connectTimeout: 15000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false
      });
      if (response.responseCode !== 200 || typeof response.result !== 'string') {
        return undefined;
      }
      const releases = JSON.parse(response.result) as GitHubRelease[];
      for (const release of releases) {
        if (release.draft || release.prerelease || !release.tag_name.toLowerCase().startsWith('harmony-v')) {
          continue;
        }
        if (isNewerVersion(release.tag_name, CURRENT_VERSION)) {
          const asset = selectInstallAsset(release.assets ?? []);
          return {
            version: release.tag_name,
            title: release.name.length > 0 ? release.name : release.tag_name,
            notes: release.body,
            pageUrl: release.html_url,
            downloadUrl: asset?.browser_download_url ?? '',
            assetName: asset?.name ?? '',
            assetSize: asset?.size ?? 0
          };
        }
      }
      return undefined;
    } catch (error) {
      const businessError = error as BusinessError;
      console.error(`检查 GitHub 版本失败: ${businessError.message}`);
      return undefined;
    } finally {
      request.destroy();
    }
  }

  async checkAppGallery(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const result = await updateManager.checkAppUpdate(context);
      if (result.updateAvailable === updateManager.UpdateAvailableCode.LATER_VERSION_EXIST) {
        await updateManager.showUpdateDialog(context);
        return true;
      }
    } catch (error) {
      const businessError = error as BusinessError;
      console.info(`AppGallery 更新检查不可用: ${businessError.code}`);
    }
    return false;
  }

  async openReleasePage(context: common.UIAbilityContext, url: string): Promise<void> {
    await context.openLink(url);
  }

  async downloadHap(context: common.UIAbilityContext, update: NativeUpdateInfo): Promise<string> {
    if (update.downloadUrl.length === 0) {
      throw new Error('该版本没有可下载的签名 HAP');
    }
    const request = http.createHttp();
    try {
      const response = await request.request(update.downloadUrl, {
        method: http.RequestMethod.GET,
        header: new GitHubHeaders(),
        connectTimeout: 20000,
        readTimeout: 120000,
        maxLimit: 200 * 1024 * 1024,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: false
      });
      if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer)) {
        throw new Error(`下载更新失败：HTTP ${response.responseCode}`);
      }
      const fileName = buildUpdateFileName(update.version, update.assetName);
      const path = `${context.filesDir}/${fileName}`;
      const file = fileIo.openSync(
        path,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      try {
        fileIo.writeSync(file.fd, response.result);
      } finally {
        fileIo.closeSync(file);
      }
      if (fileName.toLowerCase().endsWith('.app.zip')) {
        const outputDir = `${context.filesDir}/qyfm-update-${Date.now()}`;
        const fileSystem: UpdateArchiveFileSystem = {
          createDirectory: (directory: string): void => {
            fileIo.mkdirSync(directory, true);
          },
          decompress: (zipPath: string, destination: string): Promise<void> => {
            return zlib.decompressFile(zipPath, destination);
          },
          list: (directory: string): string[] => {
            return fileIo.listFileSync(directory);
          }
        };
        return await extractAppPackage(fileSystem, path, outputDir);
      }
      return path;
    } catch (error) {
      const businessError = error as BusinessError;
      throw new Error(businessError.message ?? '下载更新失败');
    } finally {
      request.destroy();
    }
  }

  async installHap(context: common.UIAbilityContext, path: string): Promise<void> {
    const uri = fileUri.getUriFromPath(path);
    await this.installUri(context, uri, path);
  }

  async installUri(context: common.UIAbilityContext, uri: string, fileName: string): Promise<void> {
    const utd = installUtdForFileName(fileName);
    if (utd.length === 0) {
      throw new Error('不支持的安装包类型');
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: uri,
      type: utd,
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION,
      parameters: {
        'ability.params.stream': [uri]
      }
    };
    await context.startAbility(want);
  }

  async openFileManager(context: common.UIAbilityContext, fileUriValue: string): Promise<void> {
    let directoryUri = fileUriValue;
    try {
      directoryUri = new fileUri.FileUri(fileUriValue).getFullDirectoryUri();
    } catch (error) {
      const businessError = error as BusinessError;
      console.info(`解析安装包目录失败: ${businessError.message ?? '未知错误'}`);
    }
    const target = buildFileManagerTarget(directoryUri);
    const want: Want = {
      bundleName: target.bundleName,
      abilityName: target.abilityName,
      action: 'ohos.want.action.viewData',
      uri: target.uri,
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION,
      parameters: {
        fileUri: target.directoryUri
      }
    };
    await context.startAbility(want);
  }
}
