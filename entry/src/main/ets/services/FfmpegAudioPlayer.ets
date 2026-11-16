import { common } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import ffmpeg from 'libqyfm_ffmpeg.so';
import { AudioPcmQueue, AudioPcmQueueReader } from '../utils/AudioPcmQueue';
import {
  pcmStartWatermark,
  pcmQueueDurationSeconds,
  shouldPrimeDecoder,
  shouldReconnectAfterPause,
  shouldStartPcmRenderer
} from '../utils/FfmpegDecodePolicy';
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
  private context: common.UIAbilityContext | undefined = undefined;
  private relay: IcecastStreamRelay | undefined = undefined;
  private hlsReader: HlsStreamReader | undefined = undefined;
  private sourceUrl: string = '';
  private renderer: audio.AudioRenderer | undefined = undefined;
  private decoderHandle: number = -1;
  private pcmQueue: AudioPcmQueue = new AudioPcmQueue(
    ffmpeg.outputSampleRate() * ffmpeg.outputChannels() * 4 * pcmQueueDurationSeconds(false)
  );
  private pcmReader: AudioPcmQueueReader = new AudioPcmQueueReader(this.pcmQueue);
  private compressedQueue: AudioPcmQueue = new AudioPcmQueue(256 * 1024);
  private decodeTask: Promise<void> | undefined = undefined;
  private creatingRenderer: boolean = false;
  private rendererTask: Promise<void> | undefined = undefined;
  private releaseTask: Promise<void> | undefined = undefined;
  private outputStopTask: Promise<void> | undefined = undefined;
  private stoppingRenderer: audio.AudioRenderer | undefined = undefined;
  private paused: boolean = false;
  private interrupted: boolean = false;
  private stopped: boolean = false;
  private fastStart: boolean = true;

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

  private readonly writeDataListener = (
    buffer: ArrayBuffer
  ): audio.AudioDataCallbackResult => {
    const output = new Uint8Array(buffer);
    if (this.paused || this.stopped) {
      output.fill(0);
    } else {
      this.pcmReader.readInto(output);
    }
    return audio.AudioDataCallbackResult.VALID;
  };

  constructor(callbacks: FfmpegPlayerCallbacks) {
    this.callbacks = callbacks;
  }

  static supports(url: string): boolean {
    return isProgressiveAudioUrl(url) || shouldUseManagedHlsReader(url);
  }

  async start(
    context: common.UIAbilityContext,
    url: string,
    fastStart: boolean = true
  ): Promise<void> {
    this.context = context;
    this.releaseTask = undefined;
    this.outputStopTask = undefined;
    this.stoppingRenderer = undefined;
    this.stopped = false;
    this.paused = false;
    this.fastStart = fastStart;
    this.sourceUrl = url;
    const managedHls = shouldUseManagedHlsReader(url);
    const pcmQueueSeconds = pcmQueueDurationSeconds(managedHls);
    this.pcmQueue = new AudioPcmQueue(
      ffmpeg.outputSampleRate() * ffmpeg.outputChannels() * 4 * pcmQueueSeconds
    );
    this.pcmReader = new AudioPcmQueueReader(this.pcmQueue);
    console.info(`FFmpeg PCM 缓冲窗口: ${pcmQueueSeconds}秒`);
    this.callbacks.onState('buffering');
    if (managedHls) {
      const hlsReader = new HlsStreamReader();
      this.hlsReader = hlsReader;
      try {
        await hlsReader.start(url, (chunk: Uint8Array): void => {
          this.enqueueDecodeChunk(chunk);
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
        this.enqueueDecodeChunk(chunk);
      });
    } catch (error) {
      const businessError = error as BusinessError;
      await this.release();
      throw new Error(businessError.message ?? 'FFmpeg 输入连接失败');
    }
  }

  async pause(): Promise<void> {
    this.paused = true;
    await this.release();
    this.callbacks.onState('paused');
  }

  async resume(): Promise<void> {
    this.paused = false;
    this.interrupted = false;
    if (shouldReconnectAfterPause(this.stopped)) {
      const releaseTask = this.releaseTask;
      if (releaseTask !== undefined) {
        await releaseTask;
      }
      const context = this.context;
      if (context !== undefined && this.sourceUrl.length > 0) {
        await this.start(context, this.sourceUrl, this.fastStart);
      }
      return;
    }
    const renderer = this.renderer;
    if (renderer !== undefined && renderer.state === audio.AudioState.STATE_PAUSED) {
      await renderer.start();
      this.callbacks.onState('playing');
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

  async releaseForSwitch(): Promise<void> {
    const releaseTask = this.release();
    await this.stopOutput();
    releaseTask.catch((error: BusinessError): void => {
      console.error(`FFmpeg 切台后台清理失败: ${error.message ?? '未知错误'}`);
    });
  }

  private stopOutput(): Promise<void> {
    if (this.outputStopTask !== undefined) {
      return this.outputStopTask;
    }
    this.outputStopTask = this.stopOutputInternal();
    return this.outputStopTask;
  }

  private async stopOutputInternal(): Promise<void> {
    this.stopped = true;
    this.relay?.destroy();
    this.relay = undefined;
    this.hlsReader?.destroy();
    this.hlsReader = undefined;
    this.compressedQueue.clear();
    this.pcmQueue.clear();
    this.pcmReader.reset();
    const renderer = this.renderer;
    this.renderer = undefined;
    this.stoppingRenderer = renderer;
    if (renderer !== undefined) {
      try {
        renderer.off('audioInterrupt', this.audioInterruptListener);
        renderer.off('writeData', this.writeDataListener);
        if (renderer.state === audio.AudioState.STATE_RUNNING ||
          renderer.state === audio.AudioState.STATE_PAUSED) {
          await renderer.stop();
        }
      } catch (error) {
        const businessError = error as BusinessError;
        console.error(`FFmpeg AudioRenderer 停止失败: ${businessError.message ?? '未知错误'}`);
      }
    }
    this.callbacks.onState('stopped');
  }

  private async releaseInternal(): Promise<void> {
    await this.stopOutput();
    const decodeTask = this.decodeTask;
    if (decodeTask !== undefined) {
      try {
        await decodeTask;
      } catch (error) {
        const businessError = error as BusinessError;
        console.error(`FFmpeg 解码任务结束异常: ${businessError.message ?? '未知错误'}`);
      }
    }
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
    const renderer = this.stoppingRenderer;
    this.stoppingRenderer = undefined;
    if (renderer !== undefined) {
      try {
        await renderer.release();
      } catch (error) {
        const businessError = error as BusinessError;
        console.error(`FFmpeg AudioRenderer 释放失败: ${businessError.message ?? '未知错误'}`);
      }
    }
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

  private enqueueDecodeChunk(chunk: Uint8Array): void {
    if (this.stopped || this.paused || chunk.length === 0) {
      return;
    }
    const copy = chunk.slice();
    this.compressedQueue.enqueue(copy.buffer);
    this.scheduleDecode();
  }

  private scheduleDecode(): void {
    if (this.decodeTask !== undefined || this.stopped || this.paused) {
      return;
    }
    const task = this.processDecodeQueue();
    this.decodeTask = task;
    task.catch((error: BusinessError): void => {
      console.error(`FFmpeg 解码分片失败: ${error.message ?? '未知错误'}`);
      this.callbacks.onState('error', error.message ?? 'FFmpeg 解码失败');
    }).finally((): void => {
      if (this.decodeTask === task) {
        this.decodeTask = undefined;
      }
      if (this.compressedQueue.byteLength > 0 && !this.paused && !this.stopped) {
        this.scheduleDecode();
      }
    });
  }

  private async processDecodeQueue(): Promise<void> {
    while (!this.stopped && !this.paused && this.compressedQueue.byteLength > 0) {
      const input = this.compressedQueue.dequeue();
      if (input === undefined) {
        return;
      }
      const decoderJustCreated = this.decoderHandle < 0;
      if (decoderJustCreated) {
        this.decoderHandle = ffmpeg.createDecoder(this.codecForChunk(new Uint8Array(input)));
      }
      const pcm = shouldPrimeDecoder(decoderJustCreated, input.byteLength)
        ? ffmpeg.decode(this.decoderHandle, input, false)
        : await ffmpeg.decodeAsync(this.decoderHandle, input, false);
      if (this.stopped) {
        return;
      }
      if (pcm.byteLength > 0 && !this.paused) {
        this.handleDecodedPcm(pcm);
      }
    }
  }

  private handleDecodedPcm(pcm: ArrayBuffer): void {
    try {
      this.pcmQueue.enqueue(pcm);
      if (this.renderer === undefined && !this.creatingRenderer &&
        shouldStartPcmRenderer(this.fastStart, this.pcmQueue.byteLength)) {
        console.info(
          `FFmpeg PCM 安全水位已满足: ${this.pcmQueue.byteLength}/${pcmStartWatermark(this.fastStart)} 字节`
        );
        const task = this.createRenderer(this.decoderHandle).catch((error: BusinessError) => {
          this.callbacks.onState('error', error.message ?? 'AudioRenderer 启动失败');
        });
        this.rendererTask = task;
        task.then((): void => {
          if (this.rendererTask === task) {
            this.rendererTask = undefined;
          }
        });
      }
    } catch (error) {
      const businessError = error as BusinessError;
      this.callbacks.onState('error', businessError.message ?? 'PCM 处理失败');
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
      renderer.on('writeData', this.writeDataListener);
      await renderer.start();
      if (!this.paused) {
        this.callbacks.onState('playing');
      }
    } finally {
      this.creatingRenderer = false;
    }
  }

}
