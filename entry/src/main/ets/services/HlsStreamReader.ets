import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import {
  detectHlsSegmentCodec,
  hasUsableHlsSegments,
  hlsInitialSegmentCount,
  hlsRequestReferer,
  HlsMediaPlaylist,
  parseHlsMediaPlaylist,
  parseHlsVariantUrl,
  stripLeadingId3
} from '../utils/HlsPlaylist';
import { AudioChunkSink } from './IcecastStreamRelay';

const USER_AGENT: string = 'QYFM-HarmonyOS/1.0.46 (FFmpeg HLS)';

class HlsRequestHeaders {
  'User-Agent': string = USER_AGENT;
  'Accept': string = '*/*';
  'Referer': string;

  constructor(referer: string) {
    this.Referer = referer;
  }
}

function wait(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, milliseconds);
  });
}

export class HlsStreamReader {
  private stopped: boolean = false;
  private activeRequest: http.HttpRequest | undefined = undefined;
  private activeBinaryRequests: Set<http.HttpRequest> = new Set<http.HttpRequest>();
  private request: http.HttpRequest | undefined = undefined;
  private loopTask: Promise<void> | undefined = undefined;
  private seenSegments: Set<string> = new Set<string>();
  private codec: 'aac' | 'mp3' | undefined = undefined;

  detectedCodec(): 'aac' | 'mp3' | undefined {
    return this.codec;
  }

  async start(url: string, sink: AudioChunkSink): Promise<void> {
    const sourceText = await this.fetchText(url, hlsRequestReferer('playlist', url, url));
    const variantUrl = parseHlsVariantUrl(sourceText, url);
    const mediaUrl = variantUrl ?? url;
    console.info(`HLS 主播放列表已读取: ${mediaUrl}`);
    const mediaText = variantUrl === undefined
      ? sourceText
      : await this.fetchText(variantUrl, hlsRequestReferer('playlist', url, variantUrl));
    const playlist = parseHlsMediaPlaylist(mediaText, mediaUrl);
    if (playlist.segments.length === 0) {
      throw new Error('HLS 播放列表中没有可播放分片');
    }
    playlist.segments.forEach((segment: string): void => {
      this.seenSegments.add(segment);
    });
    console.info(`HLS 当前分片数=${playlist.segments.length}，目标时长=${playlist.targetDurationSeconds}s`);
    const initialCount = hlsInitialSegmentCount(playlist.targetDurationSeconds);
    const initialSegments: string[] = playlist.segments.slice(
      Math.max(0, playlist.segments.length - initialCount)
    );
    await this.appendSegments(initialSegments, sink, mediaUrl);
    console.info(`HLS 首轮已交给 FFmpeg: ${initialSegments.length}片`);
    this.loopTask = this.refreshLoop(mediaUrl, playlist.targetDurationSeconds, sink, url);
  }

  destroy(): void {
    this.stopped = true;
    const request = this.activeRequest;
    this.activeRequest = undefined;
    if (request !== undefined) {
      try {
        request.destroy();
      } catch (error) {
        const businessError = error as BusinessError;
        console.info(`停止 HLS 请求失败: ${businessError.message ?? '未知错误'}`);
      }
    }
    this.request = undefined;
    this.activeBinaryRequests.forEach((binaryRequest: http.HttpRequest): void => {
      try {
        binaryRequest.destroy();
      } catch (error) {
        const businessError = error as BusinessError;
        console.info(`停止 HLS 分片请求失败: ${businessError.message ?? '未知错误'}`);
      }
    });
    this.activeBinaryRequests.clear();
  }

  private async refreshLoop(
    mediaUrl: string,
    targetDurationSeconds: number,
    sink: AudioChunkSink,
    masterUrl: string
  ): Promise<void> {
    let failures = 0;
    while (!this.stopped) {
      await wait(Math.max(500, Math.min(1500, targetDurationSeconds * 700)));
      if (this.stopped) {
        return;
      }
      try {
        const text = await this.fetchText(
          mediaUrl,
          hlsRequestReferer('playlist', masterUrl, mediaUrl)
        );
        const playlist: HlsMediaPlaylist = parseHlsMediaPlaylist(text, mediaUrl);
        const pending = playlist.segments.filter(
          (segment: string): boolean => !this.seenSegments.has(segment)
        );
        playlist.segments.forEach((segment: string): void => {
          this.seenSegments.add(segment);
        });
        const selected = pending.length > 3 ? pending.slice(pending.length - 2) : pending;
        if (selected.length > 0) {
          await this.appendSegments(selected, sink, mediaUrl);
        }
        if (this.seenSegments.size > 256) {
          this.seenSegments.clear();
          playlist.segments.slice(-2).forEach((segment: string): void => {
            this.seenSegments.add(segment);
          });
        }
        failures = 0;
      } catch (error) {
        if (this.stopped) {
          return;
        }
        failures++;
        const businessError = error as BusinessError;
        console.info(`HLS 分片刷新失败（${failures}）: ${businessError.message ?? '未知错误'}`);
        await wait(Math.min(4000, 600 * failures));
      }
    }
  }

  private async appendSegments(
    segmentUrls: string[],
    sink: AudioChunkSink,
    mediaUrl: string
  ): Promise<void> {
    const referer = hlsRequestReferer('segment', mediaUrl, mediaUrl);
    const chunks: Array<ArrayBuffer | undefined> = await Promise.all(
      segmentUrls.map((segmentUrl: string): Promise<ArrayBuffer | undefined> => {
        return this.fetchBinary(segmentUrl, referer).catch(
          (error: BusinessError): undefined => {
            console.info(`HLS 过期分片已跳过: ${error.message ?? '未知错误'}`);
            return undefined;
          }
        );
      })
    );
    if (this.stopped) {
      return;
    }
    if (!hasUsableHlsSegments(chunks)) {
      throw new Error('本轮 HLS 分片已全部过期');
    }
    let delivered = 0;
    for (const data of chunks) {
      if (data === undefined || data.byteLength <= 0) {
        continue;
      }
      const audio = stripLeadingId3(new Uint8Array(data));
      const codec = detectHlsSegmentCodec(audio);
      if (codec === undefined) {
        console.info('HLS 分片编码不受独立解码器支持，已跳过');
        continue;
      }
      this.codec = codec;
      sink(audio);
      delivered++;
    }
    if (delivered === 0) {
      throw new Error('本轮 HLS 分片编码不受支持');
    }
  }

  private async fetchText(url: string, referer: string): Promise<string> {
    const request = this.ensureRequest();
    this.activeRequest = request;
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: new HlsRequestHeaders(referer),
        connectTimeout: 6000,
        readTimeout: 8000,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false
      });
      if (response.responseCode < 200 || response.responseCode >= 300 ||
        typeof response.result !== 'string') {
        throw new Error(`HLS 播放列表请求失败：HTTP ${response.responseCode}`);
      }
      return response.result;
    } catch (error) {
      this.resetRequest(request);
      const businessError = error as BusinessError;
      throw new Error(businessError.message ?? 'HLS 播放列表请求失败');
    }
  }

  private async fetchBinary(url: string, referer: string): Promise<ArrayBuffer> {
    const request = http.createHttp();
    this.activeBinaryRequests.add(request);
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: new HlsRequestHeaders(referer),
        connectTimeout: 6000,
        readTimeout: 8000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: false
      });
      if (response.responseCode < 200 || response.responseCode >= 300 ||
        !(response.result instanceof ArrayBuffer)) {
        throw new Error(`HLS 音频分片请求失败：HTTP ${response.responseCode}`);
      }
      return response.result;
    } catch (error) {
      const businessError = error as BusinessError;
      throw new Error(businessError.message ?? 'HLS 音频分片请求失败');
    } finally {
      this.activeBinaryRequests.delete(request);
      try {
        request.destroy();
      } catch (error) {
        const businessError = error as BusinessError;
        console.info(`释放 HLS 分片请求失败: ${businessError.message ?? '未知错误'}`);
      }
    }
  }

  private ensureRequest(): http.HttpRequest {
    if (this.request === undefined) {
      this.request = http.createHttp();
    }
    return this.request;
  }

  private resetRequest(request: http.HttpRequest): void {
    try {
      request.destroy();
    } catch (error) {
      const businessError = error as BusinessError;
      console.info(`重置 HLS 请求失败: ${businessError.message ?? '未知错误'}`);
    }
    if (this.request === request) {
      this.request = undefined;
    }
    if (this.activeRequest === request) {
      this.activeRequest = undefined;
    }
  }
}
