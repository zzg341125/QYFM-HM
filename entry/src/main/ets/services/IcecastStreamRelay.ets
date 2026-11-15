import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { http, socket } from '@kit.NetworkKit';
import {
  AudioCodec,
  HttpChunkDecoder,
  HttpEndpoint,
  IcyMetadataStripper,
  isProgressiveAudioUrl,
  parseAudioCodec,
  parseAudioCodecFromHeaderText,
  parseHttpEndpoint,
  parseIcyMetaint,
  parseIcyMetaintFromHeaderText,
  parseHttpRedirectLocation
} from '../utils/IcyMetadata';
import { resolveHlsUrl } from '../utils/HlsPlaylist';

const PREPARE_TIMEOUT_MS: number = 4000;
const PLAYBACK_POLL_MS: number = 20;
const MAX_HEADER_BYTES: number = 64 * 1024;

export type AudioChunkSink = (chunk: Uint8Array) => void;

function concatBytes(left: Uint8Array, right: Uint8Array): Uint8Array {
  const joined = new Uint8Array(left.length + right.length);
  joined.set(left, 0);
  joined.set(right, left.length);
  return joined;
}

function findHeaderBoundary(data: Uint8Array): number {
  for (let index = 0; index + 3 < data.length; index++) {
    if (data[index] === 13 && data[index + 1] === 10 &&
      data[index + 2] === 13 && data[index + 3] === 10) {
      return index;
    }
  }
  return -1;
}

function decodeAscii(data: Uint8Array): string {
  let value = '';
  data.forEach((byte: number) => {
    value += String.fromCharCode(byte);
  });
  return value;
}

export class IcecastStreamRelay {
  private request: http.HttpRequest | undefined = undefined;
  private tcpSocket: socket.TCPSocket | undefined = undefined;
  private tlsSocket: socket.TLSSocket | undefined = undefined;
  private path: string = '';
  private writeFd: number = -1;
  private readFd: number = -1;
  private written: number = 0;
  private readPosition: number = 0;
  private icyMetaint: number = 0;
  private codec: AudioCodec | undefined = undefined;
  private headerKnown: boolean = false;
  private chunked: boolean = false;
  private headerBuffer: Uint8Array = new Uint8Array(0);
  private chunkDecoder: HttpChunkDecoder = new HttpChunkDecoder();
  private pendingInput: ArrayBuffer[] = [];
  private ended: boolean = false;
  private failed: boolean = false;
  private destroyed: boolean = false;
  private passthrough: boolean = false;
  private dataSink: AudioChunkSink | undefined = undefined;
  private stripper: IcyMetadataStripper = new IcyMetadataStripper();
  private sourceUrl: string = '';
  private redirectCount: number = 0;

  private readonly socketMessageListener = (info: socket.SocketMessageInfo): void => {
    this.handleSocketMessage(info.message);
  };

  private readonly socketCloseListener = (): void => {
    this.ended = true;
  };

  private readonly socketErrorListener = (error: BusinessError): void => {
    this.failed = true;
    console.error(`Icecast TCP 连接失败: ${error.message ?? '未知错误'}`);
  };

  static supports(url: string): boolean {
    return isProgressiveAudioUrl(url);
  }

  detectedCodec(): AudioCodec | undefined {
    return this.codec;
  }

  async startStream(
    context: common.UIAbilityContext,
    url: string,
    dataSink: AudioChunkSink
  ): Promise<void> {
    console.info(`FFmpeg 直播输入启动: ${url}`);
    this.dataSink = dataSink;
    this.passthrough = true;
    this.sourceUrl = url;
    const endpoint = parseHttpEndpoint(url);
    if (endpoint !== undefined) {
      if (endpoint.secure) {
        await this.startTlsRequest(endpoint);
      } else {
        await this.startTcpRequest(endpoint);
      }
    } else {
      this.startHttpRequest(url);
    }
    const deadline = Date.now() + PREPARE_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (this.failed) {
        this.destroy();
        throw new Error('FFmpeg 音频输入连接失败');
      }
      if (this.headerKnown) {
        return;
      }
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, PLAYBACK_POLL_MS);
      });
    }
    this.destroy();
    throw new Error('FFmpeg 音频输入连接超时');
  }

  async prepare(
    context: common.UIAbilityContext,
    url: string,
    fastStart: boolean
  ): Promise<media.AVDataSrcDescriptor | undefined> {
    console.info(`Icecast 兼容模式检测: ${url}`);
    this.sourceUrl = url;
    this.path = `${context.cacheDir}/qyfm-icy-${Date.now()}.mp3`;
    this.writeFd = fileIo.openSync(
      this.path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
    ).fd;
    const endpoint = parseHttpEndpoint(url);
    if (endpoint !== undefined) {
      if (endpoint.secure) {
        await this.startTlsRequest(endpoint);
      } else {
        await this.startTcpRequest(endpoint);
      }
    } else {
      this.startHttpRequest(url);
    }

    const minimumPrebuffer = fastStart ? 2048 : 16384;
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
      if (this.icyMetaint > 0 && (this.written >= minimumPrebuffer ||
        (this.ended && this.written > 0))) {
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
      console.error(`释放 Icecast HTTP 请求失败: ${businessError.message ?? '未知错误'}`);
    }
    try {
      this.tcpSocket?.off('message', this.socketMessageListener);
      this.tcpSocket?.off('close', this.socketCloseListener);
      this.tcpSocket?.off('error', this.socketErrorListener);
      this.tcpSocket?.close().catch((error: BusinessError): void => {
        console.info(`关闭 Icecast TCP 连接: ${error.message ?? '未知错误'}`);
      });
    } catch (error) {
      const businessError = error as BusinessError;
      console.error(`释放 Icecast TCP 请求失败: ${businessError.message ?? '未知错误'}`);
    }
    try {
      this.tlsSocket?.off('message', this.socketMessageListener);
      this.tlsSocket?.off('close', this.socketCloseListener);
      this.tlsSocket?.off('error', this.socketErrorListener);
      this.tlsSocket?.close().catch((error: BusinessError): void => {
        console.info(`关闭 Icecast TLS 连接: ${error.message ?? '未知错误'}`);
      });
    } catch (error) {
      const businessError = error as BusinessError;
      console.error(`释放 Icecast TLS 请求失败: ${businessError.message ?? '未知错误'}`);
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

  private async startTcpRequest(endpoint: HttpEndpoint): Promise<void> {
    const tcp = socket.constructTCPSocketInstance();
    this.tcpSocket = tcp;
    tcp.on('message', this.socketMessageListener);
    tcp.on('close', this.socketCloseListener);
    tcp.on('error', this.socketErrorListener);
    await tcp.connect({
      address: {
        address: endpoint.host,
        family: 1,
        port: endpoint.port
      },
      timeout: 15000
    });
    await tcp.send({ data: this.buildRequest(endpoint), encoding: 'UTF-8' });
  }

  private async startTlsRequest(endpoint: HttpEndpoint): Promise<void> {
    const tls = socket.constructTLSSocketInstance();
    this.tlsSocket = tls;
    tls.on('message', this.socketMessageListener);
    tls.on('close', this.socketCloseListener);
    tls.on('error', this.socketErrorListener);
    await tls.bind({
      address: '0.0.0.0',
      family: 1,
      port: 0
    });
    await tls.connect({
      address: {
        address: endpoint.host,
        family: 1,
        port: endpoint.port
      },
      secureOptions: {
        protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13]
      },
      ALPNProtocols: ['http/1.1'],
      timeout: 15000
    });
    await tls.send(this.buildRequest(endpoint));
  }

  private buildRequest(endpoint: HttpEndpoint): string {
    return `GET ${endpoint.path} HTTP/1.1\r\n` +
      `Host: ${endpoint.hostHeader}\r\n` +
      'User-Agent: QYFM-HarmonyOS/1.0.28 (AVPlayer)\r\n' +
      'Accept: */*\r\n' +
      'Icy-MetaData: 1\r\n' +
      'Connection: keep-alive\r\n\r\n';
  }

  private startHttpRequest(url: string): void {
    const request = http.createHttp();
    this.request = request;
    request.on('headersReceive', (headers: Object): void => {
      if (this.headerKnown || this.destroyed) {
        return;
      }
      this.headerKnown = true;
      this.icyMetaint = parseIcyMetaint(headers);
      this.codec = parseAudioCodec(headers);
      this.configureStripper();
      const pending = this.pendingInput;
      this.pendingInput = [];
      pending.forEach((chunk: ArrayBuffer) => {
        this.appendCleanAudio(new Uint8Array(chunk));
      });
    });
    request.on('dataReceive', (chunk: ArrayBuffer): void => {
      if (this.destroyed) {
        return;
      }
      if (!this.headerKnown) {
        this.pendingInput.push(chunk);
        return;
      }
      this.appendCleanAudio(new Uint8Array(chunk));
    });
    request.on('dataEnd', (): void => {
      this.ended = true;
    });
    const headers: Record<string, string> = {
      'User-Agent': 'QYFM-HarmonyOS/1.0.28 (AVPlayer)',
      'Icy-MetaData': '1',
      'Accept': '*/*'
    };
    request.requestInStream(url, {
      method: http.RequestMethod.GET,
      header: headers,
      usingCache: false,
      connectTimeout: 15000,
      readTimeout: 0
    }).then((responseCode: number): void => {
      if (responseCode < 200 || responseCode >= 300) {
        this.failed = true;
      }
    }).catch((error: BusinessError): void => {
      console.info(`Icecast HTTPS 流请求状态: ${error.message ?? '连接结束'}`);
    });
  }

  private handleSocketMessage(chunk: ArrayBuffer): void {
    if (this.destroyed) {
      return;
    }
    let data = new Uint8Array(chunk);
    if (!this.headerKnown) {
      this.headerBuffer = concatBytes(this.headerBuffer, data);
      const boundary = findHeaderBoundary(this.headerBuffer);
      if (boundary < 0) {
        if (this.headerBuffer.length > MAX_HEADER_BYTES) {
          this.failed = true;
        }
        return;
      }
      const headerText = decodeAscii(this.headerBuffer.slice(0, boundary + 4));
      const redirectLocation = parseHttpRedirectLocation(headerText);
      if (redirectLocation !== undefined) {
        this.headerBuffer = new Uint8Array(0);
        this.followRedirect(redirectLocation);
        return;
      }
      if (!/^(?:HTTP\/1\.[01]|ICY) 2\d\d/i.test(headerText)) {
        this.failed = true;
        return;
      }
      this.headerKnown = true;
      this.icyMetaint = parseIcyMetaintFromHeaderText(headerText);
      this.codec = parseAudioCodecFromHeaderText(headerText);
      this.chunked = /transfer-encoding\s*:\s*chunked/i.test(headerText);
      this.configureStripper();
      data = this.headerBuffer.slice(boundary + 4);
      this.headerBuffer = new Uint8Array(0);
    }
    if (data.length === 0) {
      return;
    }
    if (this.icyMetaint <= 0) {
      if (this.passthrough) {
        this.appendCleanAudio(data);
      }
      return;
    }
    if (this.chunked) {
      const decoded = this.chunkDecoder.push(data);
      if (decoded.length > 0) {
        this.appendCleanAudio(decoded);
      }
      if (this.chunkDecoder.isEnded()) {
        this.ended = true;
      }
    } else {
      this.appendCleanAudio(data);
    }
  }

  private configureStripper(): void {
    console.info(`Icecast 兼容流 metaint=${this.icyMetaint}`);
    if (this.icyMetaint > 0) {
      this.stripper.configure(this.icyMetaint);
    }
  }

  private followRedirect(location: string): void {
    if (this.redirectCount >= 5 || this.destroyed) {
      this.failed = true;
      return;
    }
    this.redirectCount++;
    const targetUrl = resolveHlsUrl(this.sourceUrl, location);
    this.sourceUrl = targetUrl;
    console.info(`Icecast 跟随跳转（${this.redirectCount}）: ${targetUrl}`);
    this.closeSocketsForRedirect()
      .then(async (): Promise<void> => {
        if (this.destroyed) {
          return;
        }
        this.headerKnown = false;
        this.icyMetaint = 0;
        this.codec = undefined;
        this.chunked = false;
        this.ended = false;
        this.failed = false;
        this.headerBuffer = new Uint8Array(0);
        this.chunkDecoder = new HttpChunkDecoder();
        this.pendingInput = [];
        const endpoint = parseHttpEndpoint(targetUrl);
        if (endpoint === undefined) {
          this.startHttpRequest(targetUrl);
        } else if (endpoint.secure) {
          await this.startTlsRequest(endpoint);
        } else {
          await this.startTcpRequest(endpoint);
        }
      })
      .catch((error: BusinessError): void => {
        console.error(`Icecast 跳转失败: ${error.message ?? '未知错误'}`);
        this.failed = true;
      });
  }

  private async closeSocketsForRedirect(): Promise<void> {
    const tcp = this.tcpSocket;
    this.tcpSocket = undefined;
    if (tcp !== undefined) {
      tcp.off('message', this.socketMessageListener);
      tcp.off('close', this.socketCloseListener);
      tcp.off('error', this.socketErrorListener);
      await tcp.close().catch((): void => {
      });
    }
    const tls = this.tlsSocket;
    this.tlsSocket = undefined;
    if (tls !== undefined) {
      tls.off('message', this.socketMessageListener);
      tls.off('close', this.socketCloseListener);
      tls.off('error', this.socketErrorListener);
      await tls.close().catch((): void => {
      });
    }
  }

  private appendCleanAudio(chunk: Uint8Array): void {
    try {
      const clean = this.stripper.strip(chunk);
      if (clean.length === 0) {
        return;
      }
      if (this.dataSink !== undefined) {
        this.dataSink(clean);
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
