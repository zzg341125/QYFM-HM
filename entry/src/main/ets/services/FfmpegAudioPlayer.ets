import { common } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import ffmpeg from 'libqyfm_ffmpeg.so';
import { inferAudioCodecFromUrl, isProgressiveAudioUrl } from '../utils/IcyMetadata';
import { shouldUseManagedHlsReader } from '../utils/HlsPlaylist';
import { HlsStreamReader } from './HlsStreamReader';
import { IcecastStreamRelay } from './IcecastStreamRelay';

export type FfmpegPlayerState = 'buffering' | 'playing' | 'paused' | 'stopped' | 'error';

export interface FfmpegPlayerCallbacks {
  onState: (state: FfmpegPlayerState, message?: string) => void;
}

export class FfmpegAudioPlayer {
  private callbacks: FfmpegPlayerCallbacks;
  private relay: IcecastStreamRelay | undefined = undefined;
  private hlsReader: HlsStreamReader | undefined = undefined;
  private sourceUrl: string = '';
  private renderer: audio.AudioRenderer | undefined = undefined;
  private decoderHandle: number = -1;
  private pcmQueue: ArrayBuffer[] = [];
  private writerRunning: boolean = false;
  private writerTask: Promise<void> | undefined = undefined;
  private creatingRenderer: boolean = false;
  private rendererTask: Promise<void> | undefined = undefined;
  private releaseTask: Promise<void> | undefined = undefined;
  private paused: boolean = false;
  private interrupted: boolean = false;
  private stopped: boolean = false;

  private readonly audioInterruptListener = (event: audio.InterruptEvent): void => {
    const begin = event.eventType === audio.InterruptType.INTERRUPT_TYPE_BEGIN;
    if (begin && (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
      event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP)) {
      this.interrupted = true;
      this.pause().catch((error: BusinessError) => {
        console.error(`FFmpeg 音频中断暂停失败: ${error.message ?? '未知错误'}`);
      });
    } else if (!begin && event.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME &&
      this.interrupted) {
      this.interrupted = false;
      this.resume().catch((error: BusinessError) => {
        console.error(`FFmpeg 音频中断恢复失败: ${error.message ?? '未知错误'}`);
      });
    }
  };

  constructor(callbacks: FfmpegPlayerCallbacks) {
    this.callbacks = callbacks;
  }

  static supports(url: string): boolean {
    return isProgressiveAudioUrl(url) || shouldUseManagedHlsReader(url);
  }

  async start(context: common.UIAbilityContext, url: string): Promise<void> {
    this.stopped = false;
    this.paused = false;
    this.sourceUrl = url;
    this.callbacks.onState('buffering');
    if (shouldUseManagedHlsReader(url)) {
      const hlsReader = new HlsStreamReader();
      this.hlsReader = hlsReader;
      try {
        await hlsReader.start(url, (chunk: Uint8Array): void => {
          this.decodeChunk(chunk);
        });
        return;
      } catch (error) {
        const businessError = error as BusinessError;
        await this.release();
        throw new Error(businessError.message ?? 'FFmpeg HLS 输入连接失败');
      }
    }
    const relay = new IcecastStreamRelay();
    this.relay = relay;
    try {
      await relay.startStream(context, url, (chunk: Uint8Array): void => {
        this.decodeChunk(chunk);
      });
    } catch (error) {
      const businessError = error as BusinessError;
      await this.release();
      throw new Error(businessError.message ?? 'FFmpeg 输入连接失败');
    }
  }

  async pause(): Promise<void> {
    this.paused = true;
    const renderer = this.renderer;
    if (renderer !== undefined && renderer.state === audio.AudioState.STATE_RUNNING) {
      await renderer.pause();
    }
    this.callbacks.onState('paused');
  }

  async resume(): Promise<void> {
    this.paused = false;
    this.interrupted = false;
    const renderer = this.renderer;
    if (renderer !== undefined && renderer.state === audio.AudioState.STATE_PAUSED) {
      await renderer.start();
      this.callbacks.onState('playing');
      this.drainPcmQueue();
    }
  }

  async release(): Promise<void> {
    if (this.releaseTask !== undefined) {
      await this.releaseTask;
      return;
    }
    this.releaseTask = this.releaseInternal();
    await this.releaseTask;
  }

  private async releaseInternal(): Promise<void> {
    if (this.stopped) {
      return;
    }
    this.stopped = true;
    this.relay?.destroy();
    this.relay = undefined;
    this.hlsReader?.destroy();
    this.hlsReader = undefined;
    this.pcmQueue = [];
    if (this.decoderHandle >= 0) {
      ffmpeg.destroyDecoder(this.decoderHandle);
      this.decoderHandle = -1;
    }
    const rendererTask = this.rendererTask;
    if (rendererTask !== undefined) {
      try {
        await rendererTask;
      } catch (error) {
        const businessError = error as BusinessError;
        console.error(`FFmpeg AudioRenderer 启动任务结束异常: ${businessError.message ?? '未知错误'}`);
      }
    }
    const writerTask = this.writerTask;
    if (writerTask !== undefined) {
      try {
        await writerTask;
      } catch (error) {
        const businessError = error as BusinessError;
        console.error(`FFmpeg PCM 写入任务结束异常: ${businessError.message ?? '未知错误'}`);
      }
    }
    const renderer = this.renderer;
    this.renderer = undefined;
    if (renderer !== undefined) {
      try {
        renderer.off('audioInterrupt', this.audioInterruptListener);
        if (renderer.state === audio.AudioState.STATE_RUNNING ||
          renderer.state === audio.AudioState.STATE_PAUSED) {
          await renderer.stop();
        }
        await renderer.release();
      } catch (error) {
        const businessError = error as BusinessError;
        console.error(`FFmpeg AudioRenderer 释放失败: ${businessError.message ?? '未知错误'}`);
      }
    }
    this.callbacks.onState('stopped');
  }

  private codecForChunk(chunk: Uint8Array): string {
    const detected = this.relay?.detectedCodec() ??
      (this.hlsReader !== undefined ? 'aac' : inferAudioCodecFromUrl(this.sourceUrl));
    if (detected === 'aac' && chunk.length >= 2 &&
      chunk[0] === 0x56 && (chunk[1] & 0xe0) === 0xe0) {
      return 'aac_latm';
    }
    return detected ?? 'mp3';
  }

  private decodeChunk(chunk: Uint8Array): void {
    if (this.stopped || chunk.length === 0) {
      return;
    }
    try {
      if (this.decoderHandle < 0) {
        this.decoderHandle = ffmpeg.createDecoder(this.codecForChunk(chunk));
      }
      const input = chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.byteLength);
      const pcm = ffmpeg.decode(this.decoderHandle, input, false);
      if (pcm.byteLength > 0) {
        this.pcmQueue.push(pcm);
        if (this.renderer === undefined && !this.creatingRenderer) {
          const task = this.createRenderer(this.decoderHandle).catch((error: BusinessError) => {
            this.callbacks.onState('error', error.message ?? 'AudioRenderer 启动失败');
          });
          this.rendererTask = task;
          task.then((): void => {
            if (this.rendererTask === task) {
              this.rendererTask = undefined;
            }
          });
        } else {
          this.drainPcmQueue();
        }
      }
    } catch (error) {
      const businessError = error as BusinessError;
      console.error(`FFmpeg 解码分片失败: ${businessError.message ?? '未知错误'}`);
      this.callbacks.onState('error', businessError.message ?? 'FFmpeg 解码失败');
    }
  }

  private async createRenderer(handle: number): Promise<void> {
    this.creatingRenderer = true;
    try {
      const sampleRate = ffmpeg.outputSampleRate();
      const channels = ffmpeg.outputChannels();
      const options: audio.AudioRendererOptions = {
        streamInfo: {
          samplingRate: sampleRate as audio.AudioSamplingRate,
          channels: channels as audio.AudioChannel,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_F32LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        rendererInfo: {
          usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
          rendererFlags: 0
        }
      };
      const renderer = await audio.createAudioRenderer(options);
      if (this.stopped || this.decoderHandle !== handle) {
        await renderer.release();
        return;
      }
      this.renderer = renderer;
      renderer.on('audioInterrupt', this.audioInterruptListener);
      await renderer.start();
      if (!this.paused) {
        this.callbacks.onState('playing');
      }
      this.drainPcmQueue();
    } finally {
      this.creatingRenderer = false;
    }
  }

  private drainPcmQueue(): void {
    if (this.writerRunning || this.paused || this.stopped) {
      return;
    }
    const renderer = this.renderer;
    if (renderer === undefined) {
      return;
    }
    this.writerRunning = true;
    const task = this.writeNext(renderer).catch((error: BusinessError) => {
      this.callbacks.onState('error', error.message ?? 'PCM 写入失败');
    }).finally((): void => {
      this.writerRunning = false;
      if (this.pcmQueue.length > 0 && !this.paused && !this.stopped) {
        this.drainPcmQueue();
      }
    });
    this.writerTask = task;
    task.then((): void => {
      if (this.writerTask === task) {
        this.writerTask = undefined;
      }
    });
  }

  private async writeNext(renderer: audio.AudioRenderer): Promise<void> {
    while (!this.paused && !this.stopped && this.pcmQueue.length > 0) {
      const pcm = this.pcmQueue.shift();
      if (pcm === undefined) {
        return;
      }
      let offset = 0;
      while (offset < pcm.byteLength && !this.stopped) {
        const written = await renderer.write(pcm.slice(offset));
        if (written <= 0) {
          break;
        }
        offset += written;
      }
    }
  }
}
