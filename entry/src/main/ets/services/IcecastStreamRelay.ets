import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { http } from '@kit.NetworkKit';
import {
  IcyMetadataStripper,
  isProgressiveMp3Url,
  parseIcyMetaint
} from '../utils/IcyMetadata';

const PREPARE_TIMEOUT_MS: number = 8000;
const PLAYBACK_POLL_MS: number = 40;

export class IcecastStreamRelay {
  private request: http.HttpRequest | undefined = undefined;
  private path: string = '';
  private writeFd: number = -1;
  private readFd: number = -1;
  private written: number = 0;
  private readPosition: number = 0;
  private icyMetaint: number = 0;
  private headerKnown: boolean = false;
  private ended: boolean = false;
  private failed: boolean = false;
  private destroyed: boolean = false;
  private pendingInput: ArrayBuffer[] = [];
  private stripper: IcyMetadataStripper = new IcyMetadataStripper();

  static supports(url: string): boolean {
    return isProgressiveMp3Url(url);
  }

  async prepare(
    context: common.UIAbilityContext,
    url: string,
    fastStart: boolean
  ): Promise<media.AVDataSrcDescriptor | undefined> {
    console.info(`Icecast 兼容模式检测: ${url}`);
    this.path = `${context.cacheDir}/qyfm-icy-${Date.now()}.mp3`;
    this.writeFd = fileIo.openSync(
      this.path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
    ).fd;
    const request = http.createHttp();
    this.request = request;
    request.on('headersReceive', (headers: Object): void => {
      this.handleHeaders(headers);
    });
    request.on('dataReceive', (chunk: ArrayBuffer): void => {
      this.handleData(chunk);
    });
    request.on('dataEnd', (): void => {
      this.ended = true;
    });
    const headers: Record<string, string> = {
      'User-Agent': 'QYFM-HarmonyOS/1.0.18 (AVPlayer)',
      'Icy-MetaData': '1',
      'Accept': '*/*'
    };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: headers,
      usingCache: false,
      connectTimeout: 15000,
      readTimeout: 0
    };
    request.requestInStream(url, options).then((responseCode: number): void => {
      if (responseCode < 200 || responseCode >= 300) {
        this.failed = true;
      }
    }).catch((error: BusinessError): void => {
      this.failed = true;
      console.error(`Icecast 兼容流请求失败: ${error.message ?? '未知错误'}`);
    });

    const minimumPrebuffer = fastStart ? 8192 : 32768;
    const deadline = Date.now() + PREPARE_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (this.failed) {
        this.destroy();
        throw new Error('Icecast 兼容流连接失败');
      }
      if (this.headerKnown && this.icyMetaint === 0) {
        this.destroy();
        return undefined;
      }
      if (this.icyMetaint > 0 && this.written >= minimumPrebuffer) {
        this.readFd = fileIo.openSync(this.path, fileIo.OpenMode.READ_ONLY).fd;
        return {
          fileSize: -1,
          callback: (buffer: ArrayBuffer, length: number): number => {
            return this.read(buffer, length);
          }
        };
      }
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, PLAYBACK_POLL_MS);
      });
    }
    this.destroy();
    return undefined;
  }

  destroy(): void {
    if (this.destroyed) {
      return;
    }
    this.destroyed = true;
    try {
      this.request?.off('headersReceive');
      this.request?.off('dataReceive');
      this.request?.off('dataEnd');
      this.request?.destroy();
    } catch (error) {
      const businessError = error as BusinessError;
      console.error(`释放 Icecast 请求失败: ${businessError.message ?? '未知错误'}`);
    }
    if (this.readFd >= 0) {
      fileIo.closeSync(this.readFd);
      this.readFd = -1;
    }
    if (this.writeFd >= 0) {
      fileIo.closeSync(this.writeFd);
      this.writeFd = -1;
    }
    if (this.path.length > 0) {
      try {
        fileIo.unlinkSync(this.path);
      } catch (error) {
        const businessError = error as BusinessError;
        console.info(`清理 Icecast 缓存失败: ${businessError.message ?? '未知错误'}`);
      }
      this.path = '';
    }
  }

  private handleHeaders(headers: Object): void {
    if (this.headerKnown) {
      return;
    }
    this.headerKnown = true;
    this.icyMetaint = parseIcyMetaint(headers);
    console.info(`Icecast 响应头: ${JSON.stringify(headers)}，metaint=${this.icyMetaint}`);
    if (this.icyMetaint <= 0) {
      return;
    }
    this.stripper.configure(this.icyMetaint);
    const pending = this.pendingInput;
    this.pendingInput = [];
    pending.forEach((chunk: ArrayBuffer) => {
      this.appendCleanAudio(chunk);
    });
  }

  private handleData(chunk: ArrayBuffer): void {
    if (this.destroyed) {
      return;
    }
    if (!this.headerKnown) {
      this.pendingInput.push(chunk);
      return;
    }
    if (this.icyMetaint <= 0) {
      return;
    }
    this.appendCleanAudio(chunk);
  }

  private appendCleanAudio(chunk: ArrayBuffer): void {
    try {
      const clean = this.stripper.strip(new Uint8Array(chunk));
      if (clean.length === 0) {
        return;
      }
      const written = fileIo.writeSync(
        this.writeFd,
        clean.buffer,
        { length: clean.length }
      );
      this.written += written;
    } catch (error) {
      this.failed = true;
      const businessError = error as BusinessError;
      console.error(`写入 Icecast 兼容流失败: ${businessError.message ?? '未知错误'}`);
    }
  }

  private read(buffer: ArrayBuffer, requestedLength: number): number {
    const available = this.written - this.readPosition;
    if (available > 0) {
      try {
        const length = Math.min(requestedLength, available);
        const readLength = fileIo.readSync(this.readFd, buffer, { length: length });
        this.readPosition += readLength;
        return readLength;
      } catch (error) {
        const businessError = error as BusinessError;
        console.error(`读取 Icecast 兼容流失败: ${businessError.message ?? '未知错误'}`);
        return -2;
      }
    }
    if (this.failed) {
      return -2;
    }
    if (this.ended) {
      return -1;
    }
    return 0;
  }
}
