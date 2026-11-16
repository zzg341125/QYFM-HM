import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import {
  hlsRequestReferer,
  HlsMediaPlaylist,
  parseHlsMediaPlaylist,
  parseHlsVariantUrl,
  stripLeadingId3
} from '../utils/HlsPlaylist';
import { AudioChunkSink } from './IcecastStreamRelay';

const USER_AGENT: string = 'QYFM-HarmonyOS/1.0.36 (FFmpeg HLS)';

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
  private request: http.HttpRequest | undefined = undefined;
  private loopTask: Promise<void> | undefined = undefined;
  private seenSegments: Set<string> = new Set<string>();

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
    await this.appendSegment(
      playlist.segments[playlist.segments.length - 1],
      sink,
      mediaUrl
    );
    console.info('HLS 首片已交给 FFmpeg');
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
        for (const segment of selected) {
          if (this.stopped) {
            return;
          }
          await this.appendSegment(segment, sink, mediaUrl);
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

  private async appendSegment(
    segmentUrl: string,
    sink: AudioChunkSink,
    mediaUrl: string
  ): Promise<void> {
    const data = await this.fetchBinary(
      segmentUrl,
      hlsRequestReferer('segment', mediaUrl, mediaUrl)
    );
    if (!this.stopped && data.byteLength > 0) {
      sink(stripLeadingId3(new Uint8Array(data)));
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
    const request = this.ensureRequest();
    this.activeRequest = request;
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
      this.resetRequest(request);
      const businessError = error as BusinessError;
      throw new Error(businessError.message ?? 'HLS 音频分片请求失败');
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
