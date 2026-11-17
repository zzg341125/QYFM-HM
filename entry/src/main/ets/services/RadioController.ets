import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { media } from '@kit.MediaKit';
import { avSession } from '@kit.AVSessionKit';
import { audio } from '@kit.AudioKit';
import { AppSettings, createDefaultSettings, Station, StreamLine } from '../models/Station';
import { BackgroundTaskService } from './BackgroundTaskService';
import { BluetoothResumeCallbacks, BluetoothResumeManager } from './BluetoothResumeManager';
import { FfmpegAudioPlayer, FfmpegPlayerState } from './FfmpegAudioPlayer';
import { IcecastStreamRelay } from './IcecastStreamRelay';
import { RadioCnResolver } from './RadioCnResolver';
import {
  audioInterruptAction,
  AudioInterruptAction,
  buildLivePlaybackTuning,
  buildPlaybackCandidates,
  PlaybackRecoveryGate,
  PlaybackCandidate,
  LivePlaybackTuning,
  sessionPlaybackMode,
  shouldAutoPlayOnBluetoothConnect,
  shouldStartBoundBluetoothPlayback,
  shouldStopForBluetoothDisconnect,
  shouldResumeStoppedBluetooth,
  shouldResumeAfterForeground,
  shouldRecoverFromBufferStall
} from '../utils/PlaybackRecovery';
import { migrateLegacyStreamUrl } from '../utils/StreamUrlRepair';
import { safeSessionArtwork } from '../utils/SessionArtwork';
import { buildDecoderAttemptOrder, DecoderEngine } from '../utils/DecoderSelection';
import { isHlsPlaylistUrl } from '../utils/HlsPlaylist';
import { sleepTimerAfterStationSwitch } from '../utils/TimeSettings';
import {
  BluetoothBinding,
  findBluetoothBinding,
  rememberBluetoothBinding
} from '../utils/BluetoothBindings';

export interface RadioSnapshot {
  currentStation: Station | undefined;
  state: string;
  isPlaying: boolean;
  waitingForBluetooth: boolean;
  statusText: string;
  diagnostics: string;
  sleepTimerMinutes: number;
  sleepTimerEndAt: number;
  bluetoothBindings: BluetoothBinding[];
}

export type RadioStateListener = (snapshot: RadioSnapshot) => void;

const SESSION_TAG: string = 'QYFM_NATIVE_SESSION';
const LIVE_USER_AGENT: string = 'QYFM-HarmonyOS/1.0.40 (AVPlayer)';

export class RadioController {
  private static instance: RadioController | undefined = undefined;

  static getInstance(): RadioController {
    if (RadioController.instance === undefined) {
      RadioController.instance = new RadioController();
    }
    return RadioController.instance;
  }

  private context: common.UIAbilityContext | undefined = undefined;
  private player: media.AVPlayer | undefined = undefined;
  private ffmpegPlayer: FfmpegAudioPlayer | undefined = undefined;
  private activeDecoderEngine: DecoderEngine | undefined = undefined;
  private decoderAttemptsTried: Set<string> = new Set<string>();
  private icyRelay: IcecastStreamRelay | undefined = undefined;
  private session: avSession.AVSession | undefined = undefined;
  private sessionActive: boolean = false;
  private currentStation: Station | undefined = undefined;
  private defaultStation: Station | undefined = undefined;
  private settings: AppSettings = createDefaultSettings();
  private listeners: RadioStateListener[] = [];
  private waitingForBluetooth: boolean = false;
  private statusText: string = '选择电台后开始播放';
  private diagnostics: string = '蓝牙监听尚未启动';
  private isPlaying: boolean = false;
  private pausedByUser: boolean = true;
  private sleepTimerMinutes: number = 0;
  private sleepTimerEndAt: number = 0;
  private sleepTimer: number = -1;
  private sleepStoppedByTimer: boolean = false;
  private retryTimer: number = -1;
  private watchdogTimer: number = -1;
  private bufferHintTimer: number = -1;
  private bufferStallTimer: number = -1;
  private retryCount: number = 0;
  private recoveryGate: PlaybackRecoveryGate = new PlaybackRecoveryGate();
  private candidatePosition: number = 0;
  private playRequestId: number = 0;
  private currentCandidates: PlaybackCandidate[] = [];
  private buffering: boolean = false;
  private audioInterrupted: boolean = false;
  private stoppedForBluetoothDeviceId: string = '';
  private stoppedForBluetoothAt: number = 0;
  private playbackRequestedAt: number = 0;
  private tuning: LivePlaybackTuning = buildLivePlaybackTuning(true);
  private backgroundTasks: BackgroundTaskService = new BackgroundTaskService();
  private radioCnResolver: RadioCnResolver = new RadioCnResolver();
  private bluetooth: BluetoothResumeManager;

  private constructor() {
    const callbacks: BluetoothResumeCallbacks = {
      onBluetoothLost: (deviceId: string): void => {
        this.handleBluetoothLost(deviceId);
      },
      onBluetoothConnected: (deviceId: string, deviceName: string): void => {
        this.handleBluetoothConnected(deviceId, deviceName);
      },
      onWindowExpired: (deviceId: string): void => {
        this.handleResumeWindowExpired(deviceId);
      },
      onDiagnostics: (message: string): void => {
        this.diagnostics = message;
        this.notify();
      }
    };
    this.bluetooth = new BluetoothResumeManager(callbacks);
  }

  async init(context: common.UIAbilityContext, settings: AppSettings): Promise<void> {
    this.context = context;
    this.settings = settings;
    this.bluetooth.setResumeWindowMinutes(settings.resumeWindowMinutes);
    if (this.shouldMonitorBluetooth() && this.context !== undefined) {
      this.bluetooth.start();
    }
    this.notify();
  }

  setDefaultStation(station: Station): void {
    this.defaultStation = station;
  }

  subscribe(listener: RadioStateListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
    listener(this.snapshot());
  }

  unsubscribe(listener: RadioStateListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  async applySettings(settings: AppSettings): Promise<void> {
    this.settings = settings;
    this.tuning = buildLivePlaybackTuning(
      settings.fastStart,
      this.currentStation !== undefined && isHlsPlaylistUrl(this.currentStation.streamUrl)
    );
    this.bluetooth.setResumeWindowMinutes(settings.resumeWindowMinutes);
    if (this.shouldMonitorBluetooth()) {
      this.bluetooth.start();
    } else {
      this.bluetooth.stop();
      this.bluetooth.cancelPending();
      if (this.waitingForBluetooth && this.context !== undefined) {
        await this.backgroundTasks.stop(this.context);
      }
      this.waitingForBluetooth = false;
    }
    this.notify();
  }

  snapshot(): RadioSnapshot {
    return {
      currentStation: this.currentStation,
      state: this.isPlaying ? 'playing' : (this.waitingForBluetooth ? 'waiting' : 'stopped'),
      isPlaying: this.isPlaying,
      waitingForBluetooth: this.waitingForBluetooth,
      statusText: this.statusText,
      diagnostics: this.diagnostics,
      sleepTimerMinutes: this.sleepTimerMinutes,
      sleepTimerEndAt: this.sleepTimerEndAt,
      bluetoothBindings: this.settings.bluetoothBindings.map(
        (binding: BluetoothBinding): BluetoothBinding => {
          return {
            deviceId: binding.deviceId,
            deviceName: binding.deviceName,
            autoPlay: binding.autoPlay,
            lastConnectedAt: binding.lastConnectedAt
          };
        }
      )
    };
  }

  async playStation(station: Station): Promise<void> {
    this.playbackRequestedAt = Date.now();
    this.decoderAttemptsTried.clear();
    console.info(`起播计时开始: ${station.name}`);
    const context = this.context;
    if (context === undefined) {
      this.statusText = '应用尚未完成初始化';
      this.notify();
      return;
    }
    const requestId = ++this.playRequestId;
    await this.recoveryGate.waitUntilIdle();
    if (requestId !== this.playRequestId) {
      return;
    }
    const sleepTimer = sleepTimerAfterStationSwitch(
      this.sleepTimerMinutes,
      this.sleepTimerEndAt,
      Date.now()
    );
    if (this.sleepTimerEndAt > 0 && sleepTimer.endAt === 0) {
      await this.stop();
      this.sleepStoppedByTimer = true;
      this.statusText = '睡眠定时已结束';
      this.notify();
      return;
    }
    this.sleepTimerMinutes = sleepTimer.minutes;
    this.sleepTimerEndAt = sleepTimer.endAt;
    this.sleepStoppedByTimer = false;
    this.waitingForBluetooth = false;
    this.pausedByUser = false;
    this.audioInterrupted = false;
    this.stoppedForBluetoothDeviceId = '';
    this.stoppedForBluetoothAt = 0;
    this.clearRecoveryTimers();
    this.retryCount = 0;
    this.candidatePosition = 0;
    this.tuning = buildLivePlaybackTuning(
      this.settings.fastStart,
      isHlsPlaylistUrl(station.streamUrl)
    );
    this.bluetooth.cancelPending();
    this.isPlaying = false;
    const migratedStation = this.migrateLegacyStation(station);
    if (requestId !== this.playRequestId) {
      return;
    }
    this.currentStation = migratedStation;
    this.currentCandidates = buildPlaybackCandidates(migratedStation);
    if (this.currentCandidates.length === 0) {
      this.statusText = '该电台暂无有效音频直播流';
      this.notify();
      return;
    }
    this.statusText = migratedStation.name;
    this.notify();
    this.prepareSessionInBackground(migratedStation);
    this.prefetchOfficialStation(migratedStation, requestId);
    this.backgroundTasks.start(context).catch((error: BusinessError) => {
      console.error(`启动播放长时任务失败，不影响前台播放: ${error.message ?? '未知错误'}`);
    });
    if (this.shouldMonitorBluetooth()) {
      this.bluetooth.setPlaybackActive(true);
    }
    try {
      await this.startCandidate(this.currentCandidates[0]);
    } catch (error) {
      const businessError = error as BusinessError;
      this.handlePlaybackFailure(`播放失败：${businessError.message ?? '未知错误'}`);
    }
  }

  async togglePlayback(): Promise<void> {
    if (this.currentStation === undefined) {
      this.statusText = '请先选择一个电台';
      this.notify();
      return;
    }
    if (this.isPlaying) {
      await this.pause('已暂停', true);
    } else {
      await this.resume('继续播放');
    }
  }

  async resume(reason: string): Promise<void> {
    if (this.currentStation === undefined) {
      return;
    }
    this.clearRecoveryTimers();
    this.waitingForBluetooth = false;
    this.pausedByUser = false;
    this.audioInterrupted = false;
    this.statusText = reason;
    this.notify();
    try {
      await this.playStation(this.currentStation);
    } catch (error) {
      const businessError = error as BusinessError;
      this.statusText = `继续播放失败：${businessError.message ?? '未知错误'}`;
      this.notify();
    }
  }

  async pause(reason: string, manual: boolean): Promise<void> {
    this.clearRecoveryTimers();
    if (manual) {
      this.playRequestId++;
      this.pausedByUser = true;
      this.audioInterrupted = false;
      this.bluetooth.cancelPending();
      this.bluetooth.setPlaybackActive(false);
    }
    await this.releaseActivePlayers(false);
    if (manual && this.context !== undefined) {
      await this.backgroundTasks.stop(this.context);
    }
    this.isPlaying = false;
    this.buffering = false;
    this.waitingForBluetooth = !manual && this.settings.autoResume;
    this.statusText = reason;
    await this.updateSessionPlaybackState(false).catch((error: BusinessError): void => {
      console.error(`更新媒体暂停状态失败: ${error.message}`);
    });
    this.notify();
  }

  async stop(): Promise<void> {
    this.playRequestId++;
    this.pausedByUser = true;
    this.audioInterrupted = false;
    this.stoppedForBluetoothDeviceId = '';
    this.stoppedForBluetoothAt = 0;
    this.clearRecoveryTimers();
    this.retryCount = 0;
    this.candidatePosition = 0;
    this.currentCandidates = [];
    this.bluetooth.cancelPending();
    this.bluetooth.setPlaybackActive(false);
    if (this.sleepTimer >= 0) {
      clearTimeout(this.sleepTimer);
      this.sleepTimer = -1;
      this.sleepTimerMinutes = 0;
      this.sleepTimerEndAt = 0;
    }
    await this.releaseActivePlayers(false);
    if (this.context !== undefined) {
      await this.backgroundTasks.stop(this.context);
    }
    this.isPlaying = false;
    this.waitingForBluetooth = false;
    this.statusText = '已停止';
    await this.updateSessionPlaybackState(false).catch((error: BusinessError): void => {
      console.error(`更新媒体停止状态失败: ${error.message}`);
    });
    this.notify();
  }

  async resumeIfPausedAfterForeground(): Promise<void> {
    if (this.sleepTimerEndAt > 0 && this.sleepTimerEndAt <= Date.now()) {
      await this.stop();
      this.sleepStoppedByTimer = true;
      this.statusText = '睡眠定时已结束';
    }
    if (!shouldResumeAfterForeground(
      this.isPlaying ? 'playing' : 'stopped',
      this.pausedByUser,
      this.waitingForBluetooth,
      this.currentStation !== undefined,
      this.sleepStoppedByTimer,
      this.settings.autoPlayOnLaunch
    )) {
      return;
    }
    const station = this.currentStation;
    if (station === undefined) {
      return;
    }
    this.statusText = '返回前台，正在恢复直播';
    await this.playStation(station);
  }

  setSleepTimer(minutes: number): void {
    if (this.sleepTimer >= 0) {
      clearTimeout(this.sleepTimer);
      this.sleepTimer = -1;
    }
    this.sleepTimerMinutes = minutes;
    if (minutes > 0) {
      this.sleepTimerEndAt = Date.now() + minutes * 60 * 1000;
      this.sleepTimer = setTimeout(() => {
        this.sleepTimer = -1;
        this.sleepTimerMinutes = 0;
        this.sleepTimerEndAt = 0;
        this.stop().then((): void => {
          this.sleepStoppedByTimer = true;
          this.statusText = '睡眠定时已结束';
          this.notify();
        }).catch((error: BusinessError): void => {
          console.error(`睡眠定时停止播放失败: ${error.message ?? '未知错误'}`);
        });
      }, minutes * 60 * 1000);
      const end = new Date(this.sleepTimerEndAt);
      const hour = end.getHours().toString().padStart(2, '0');
      const minute = end.getMinutes().toString().padStart(2, '0');
      this.statusText = `${minutes} 分钟后于 ${hour}:${minute} 停止播放`;
    } else {
      this.sleepTimerEndAt = 0;
      this.sleepStoppedByTimer = false;
      this.statusText = '睡眠定时已关闭';
    }
    this.notify();
  }

  private async startCandidate(candidate: PlaybackCandidate): Promise<void> {
    const station = this.currentStation;
    if (station === undefined) {
      return;
    }
    const lines: StreamLine[] | undefined = station.streamLines?.map((line: StreamLine): StreamLine => {
      return {
        id: line.id,
        name: line.name,
        url: line.url,
        priority: line.priority,
        isStable: line.isStable
      };
    });
    const nextStation: Station = {
      id: station.id,
      name: station.name,
      streamUrl: candidate.url,
      streamLines: lines,
      activeLineIndex: candidate.lineIndex,
      iconUrl: station.iconUrl,
      tags: station.tags,
      country: station.country,
      state: station.state,
      favorite: station.favorite
    };
    this.currentStation = nextStation;
    this.tuning = buildLivePlaybackTuning(
      this.settings.fastStart,
      isHlsPlaylistUrl(candidate.url)
    );
    this.decoderAttemptsTried.clear();
    this.statusText = station.name;
    this.notify();
    await this.replacePlayer(candidate, undefined, this.playRequestId);
  }

  private migrateLegacyStation(station: Station): Station {
    const lines: StreamLine[] | undefined = station.streamLines?.map((line: StreamLine): StreamLine => {
      return {
        id: line.id,
        name: line.name,
        url: migrateLegacyStreamUrl(line.url),
        priority: line.priority,
        isStable: line.isStable
      };
    });
    return {
      id: station.id,
      name: station.name,
      streamUrl: migrateLegacyStreamUrl(station.streamUrl),
      streamLines: lines,
      activeLineIndex: station.activeLineIndex ?? 0,
      iconUrl: station.iconUrl,
      tags: station.tags,
      country: station.country,
      state: station.state,
      favorite: station.favorite
    };
  }

  private decoderAttemptKey(url: string, engine: DecoderEngine): string {
    return `${url}\n${engine}`;
  }

  private async replacePlayer(
    candidate: PlaybackCandidate,
    forcedEngine?: DecoderEngine,
    requestId: number = this.playRequestId
  ): Promise<void> {
    console.info(`准备播放线路: ${candidate.url}`);
    this.clearRecoveryTimers();
    this.buffering = true;
    await this.releaseActivePlayers(true);
    if (requestId !== this.playRequestId) {
      throw new Error('播放请求已取消');
    }
    const context = this.context;
    if (context === undefined) {
      throw new Error('应用尚未完成初始化');
    }
    const attempts = buildDecoderAttemptOrder(
      candidate.url,
      FfmpegAudioPlayer.supports(candidate.url)
    );
    const orderedAttempts = forcedEngine === undefined
      ? attempts
      : attempts.filter((engine: DecoderEngine): boolean => engine === forcedEngine);
    let lastError: Error | undefined = undefined;
    for (const engine of orderedAttempts) {
      const key = this.decoderAttemptKey(candidate.url, engine);
      if (this.decoderAttemptsTried.has(key)) {
        continue;
      }
      this.decoderAttemptsTried.add(key);
      this.activeDecoderEngine = engine;
      try {
        if (engine === 'ffmpeg') {
          await this.startFfmpegAttempt(context, candidate.url, requestId);
        } else {
          await this.startNativeAttempt(candidate.url, requestId);
        }
        return;
      } catch (error) {
        const caught = error as Error;
        lastError = caught;
        if (requestId !== this.playRequestId) {
          throw caught;
        }
        await this.releaseActivePlayers(true);
        console.error(`解码后端 ${engine} 启动失败: ${caught.message ?? '未知错误'}`);
      }
    }
    throw lastError ?? new Error('没有可用的音频解码后端');
  }

  private async startFfmpegAttempt(
    context: common.UIAbilityContext,
    url: string,
    requestId: number
  ): Promise<void> {
    const ffmpegPlayer = new FfmpegAudioPlayer({
      onState: (state: FfmpegPlayerState, message?: string): void => {
        this.handleFfmpegPlayerState(ffmpegPlayer, state, message);
      }
    });
    this.ffmpegPlayer = ffmpegPlayer;
    try {
      await ffmpegPlayer.start(context, url, this.settings.fastStart);
      if (requestId !== this.playRequestId || this.ffmpegPlayer !== ffmpegPlayer) {
        await ffmpegPlayer.release();
        throw new Error('播放请求已取消');
      }
    } catch (error) {
      if (this.ffmpegPlayer === ffmpegPlayer) {
        this.ffmpegPlayer = undefined;
      }
      await ffmpegPlayer.release().catch((releaseError: BusinessError): void => {
        console.error(`释放失败的 FFmpeg 播放器失败: ${releaseError.message ?? '未知错误'}`);
      });
      const caught = error as Error;
      throw caught;
    }
  }

  private async startNativeAttempt(url: string, requestId: number): Promise<void> {
    const player = await media.createAVPlayer();
    if (requestId !== this.playRequestId) {
      await player.release();
      throw new Error('播放请求已取消');
    }
    this.player = player;
    player.on('stateChange', (state: string) => {
      if (this.player !== player) {
        return;
      }
      this.handlePlayerState(player, state).catch((error: BusinessError) => {
        this.statusText = `播放状态处理失败：${error.message}`;
        this.notify();
      });
    });
    player.on('error', (error: BusinessError) => {
      if (this.player !== player) {
        return;
      }
      this.handlePlaybackFailure(`播放器错误：${error.message ?? '未知错误'}`, player);
    });
    player.on('bufferingUpdate', (infoType: media.BufferingInfoType) => {
      if (this.player !== player) {
        return;
      }
      if (infoType === media.BufferingInfoType.BUFFERING_START) {
        console.info(`直播缓冲开始: ${Date.now() - this.playbackRequestedAt}ms`);
        this.buffering = true;
        if (this.isPlaying) {
          this.scheduleBufferHint();
          this.scheduleBufferStallRecovery(player);
        }
        this.startWatchdog(player);
      } else if (infoType === media.BufferingInfoType.BUFFERING_END) {
        console.info(`直播缓冲结束: ${Date.now() - this.playbackRequestedAt}ms`);
        this.buffering = false;
        this.clearBufferHint();
        this.clearBufferStallRecovery();
        this.clearWatchdog();
      }
    });
    player.on('audioInterrupt', (event: audio.InterruptEvent) => {
      if (this.player !== player) {
        return;
      }
      this.handleAudioInterrupt(event);
    });
    const context = this.context;
    if (this.settings.icecastCompatibility && IcecastStreamRelay.supports(url) &&
      context !== undefined) {
      const relay = new IcecastStreamRelay();
      try {
        const relaySource = await relay.prepare(
          context,
          url,
          this.settings.fastStart
        );
        if (relaySource !== undefined && this.player === player &&
          requestId === this.playRequestId) {
          this.icyRelay = relay;
          player.dataSrc = relaySource;
        } else {
          relay.destroy();
          await this.setUrlMediaSource(player, url);
        }
      } catch (error) {
        relay.destroy();
        const businessError = error as BusinessError;
        console.error(`Icecast 兼容模式失败，改用系统直连: ${businessError.message ?? '未知错误'}`);
        await this.setUrlMediaSource(player, url);
      }
    } else {
      await this.setUrlMediaSource(player, url);
    }
    if (requestId !== this.playRequestId || this.player !== player) {
      await player.release();
      throw new Error('播放请求已取消');
    }
    this.startWatchdog(player);
  }

  private async releaseActivePlayers(fastSwitch: boolean): Promise<void> {
    const player = this.player;
    const ffmpegPlayer = this.ffmpegPlayer;
    const relay = this.icyRelay;
    this.player = undefined;
    this.ffmpegPlayer = undefined;
    this.icyRelay = undefined;
    this.activeDecoderEngine = undefined;
    relay?.destroy();
    if (player !== undefined) {
      try {
        await player.release();
      } catch (error) {
        const businessError = error as BusinessError;
        console.error(`释放原生播放器失败: ${businessError.message ?? '未知错误'}`);
      }
    }
    if (ffmpegPlayer !== undefined) {
      try {
        if (fastSwitch) {
          await ffmpegPlayer.releaseForSwitch();
        } else {
          await ffmpegPlayer.release();
        }
      } catch (error) {
        const businessError = error as BusinessError;
        console.error(`释放 FFmpeg 播放器失败: ${businessError.message ?? '未知错误'}`);
      }
    }
  }

  private async setUrlMediaSource(player: media.AVPlayer, url: string): Promise<void> {
    const headers: Record<string, string> = {
      'User-Agent': LIVE_USER_AGENT,
      'Accept': '*/*'
    };
    const source = media.createMediaSourceWithUrl(url, headers);
    await player.setMediaSource(source);
  }

  private async handlePlayerState(player: media.AVPlayer, state: string): Promise<void> {
    console.info(`播放器状态 ${state}: ${Date.now() - this.playbackRequestedAt}ms`);
    if (state === 'initialized') {
      player.audioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0
      };
      const strategy: media.PlaybackStrategy = {
        preferredBufferDuration: this.tuning.preferredBufferDuration,
        preferredBufferDurationForPlaying: this.tuning.preferredBufferDurationForPlaying,
        thresholdForAutoQuickPlay: this.tuning.thresholdForAutoQuickPlay
      };
      await player.setPlaybackStrategy(strategy);
      await player.prepare();
    } else if (state === 'prepared') {
      player.audioInterruptMode = audio.InterruptMode.SHARE_MODE;
      await player.play();
      this.startWatchdog(player);
    } else if (state === 'playing') {
      this.clearWatchdog();
      this.clearBufferHint();
      this.clearBufferStallRecovery();
      this.buffering = false;
      this.retryCount = 0;
      this.isPlaying = true;
      this.waitingForBluetooth = false;
      this.statusText = this.currentStation?.name ?? '正在播放';
      await this.updateSessionPlaybackState(true);
      this.notify();
    } else if (state === 'paused') {
      this.isPlaying = false;
      this.clearBufferHint();
      this.clearBufferStallRecovery();
      this.buffering = false;
      if (!this.waitingForBluetooth) {
        this.statusText = this.audioInterrupted ? '音频暂时被其他应用占用' : '已暂停';
      }
      await this.updateSessionPlaybackState(false);
      this.notify();
    } else if (state === 'completed' || state === 'stopped') {
      this.isPlaying = false;
      this.clearBufferHint();
      this.clearBufferStallRecovery();
      this.buffering = false;
      await this.updateSessionPlaybackState(false);
      if (this.pausedByUser || this.waitingForBluetooth || this.audioInterrupted) {
        this.statusText = this.pausedByUser ? '播放已停止' : '等待音频恢复';
        this.notify();
        return;
      }
      this.handlePlaybackFailure('直播流已中断', player);
    }
  }

  private handleFfmpegPlayerState(
    player: FfmpegAudioPlayer,
    state: FfmpegPlayerState,
    message?: string
  ): void {
    if (this.ffmpegPlayer !== player) {
      return;
    }
    console.info(`FFmpeg 播放器状态 ${state}: ${Date.now() - this.playbackRequestedAt}ms`);
    if (state === 'buffering') {
      this.buffering = true;
      this.startFfmpegWatchdog(player);
      return;
    }
    if (state === 'playing') {
      this.clearWatchdog();
      this.clearBufferHint();
      this.buffering = false;
      this.retryCount = 0;
      this.isPlaying = true;
      this.waitingForBluetooth = false;
      this.statusText = this.currentStation?.name ?? '正在播放';
      this.updateSessionPlaybackState(true).catch((error: BusinessError) => {
        console.error(`更新 FFmpeg 媒体状态失败: ${error.message ?? '未知错误'}`);
      });
      this.notify();
      return;
    }
    if (state === 'paused') {
      this.isPlaying = false;
      this.buffering = false;
      this.clearBufferHint();
      if (!this.waitingForBluetooth) {
        this.statusText = '已暂停';
      }
      this.updateSessionPlaybackState(false).catch((error: BusinessError): void => {
        console.error(`隐藏 FFmpeg 暂停媒体通知失败: ${error.message}`);
      });
      this.notify();
      return;
    }
    if (state === 'error') {
      this.handlePlaybackFailure(`独立 FFmpeg 播放失败：${message ?? '未知错误'}`);
    }
  }

  private handlePlaybackFailure(reason: string, failedPlayer?: media.AVPlayer): void {
    if (failedPlayer !== undefined && this.player !== failedPlayer) {
      return;
    }
    if (this.pausedByUser || this.waitingForBluetooth || this.audioInterrupted ||
      this.currentStation === undefined || this.currentCandidates.length === 0) {
      this.notify();
      return;
    }
    this.recoveryGate.run(async (): Promise<void> => {
      await this.recoverPlaybackFailure(reason, failedPlayer);
    }).then((started: boolean): void => {
      if (!started) {
        console.info('忽略并发播放恢复请求');
      }
    }).catch((error: BusinessError): void => {
      console.error(`播放恢复流程失败: ${error.message ?? '未知错误'}`);
    });
  }

  private async recoverPlaybackFailure(reason: string, failedPlayer?: media.AVPlayer): Promise<void> {
    const requestId = this.playRequestId;
    this.clearRecoveryTimers();
    this.buffering = false;
    this.isPlaying = false;
    await this.releaseActivePlayers(true);
    await this.updateSessionPlaybackState(false).catch((error: BusinessError): void => {
      console.error(`更新媒体停止状态失败: ${error.message}`);
    });
    if (requestId !== this.playRequestId || this.currentStation === undefined ||
      this.pausedByUser || this.waitingForBluetooth || this.audioInterrupted) {
      return;
    }

    const currentLine = this.currentCandidates[this.candidatePosition];
    const fallbackEngine = buildDecoderAttemptOrder(
      currentLine.url,
      FfmpegAudioPlayer.supports(currentLine.url)
    ).find((engine: DecoderEngine): boolean => {
      return !this.decoderAttemptsTried.has(this.decoderAttemptKey(currentLine.url, engine));
    });
    if (fallbackEngine !== undefined) {
      this.statusText = fallbackEngine === 'ffmpeg'
        ? '系统播放不稳定，正在切换兼容解码'
        : '兼容解码失败，正在切换系统播放';
      this.notify();
      try {
        await this.replacePlayer(currentLine, fallbackEngine, requestId);
      } catch (error) {
        const businessError = error as BusinessError;
        await this.recoverPlaybackFailure(
          `同线路切换解码失败：${businessError.message ?? '未知错误'}`
        );
      }
      return;
    }

    const nextPosition = this.candidatePosition + 1;
    if (nextPosition < this.currentCandidates.length) {
      this.candidatePosition = nextPosition;
      const next = this.currentCandidates[nextPosition];
      this.statusText = `正在无感切换备用线路：${next.name}`;
      this.notify();
      try {
        await this.startCandidate(next);
      } catch (error) {
        const businessError = error as BusinessError;
        await this.recoverPlaybackFailure(
          `备用线路连接失败：${businessError.message ?? '未知错误'}`
        );
      }
      return;
    }

    if (this.retryCount < this.tuning.maxAutoRetries) {
      this.retryCount++;
      const current = this.currentCandidates[this.candidatePosition];
      this.statusText =
        `正在刷新直播线路（${this.retryCount}/${this.tuning.maxAutoRetries}）：${current.name}`;
      this.notify();
      this.retryTimer = setTimeout(() => {
        this.retryTimer = -1;
        this.recoveryGate.run(async (): Promise<void> => {
          try {
            await this.startCandidate(current);
          } catch (error) {
            const businessError = error as BusinessError;
            await this.recoverPlaybackFailure(
              `自动恢复失败：${businessError.message ?? '未知错误'}`
            );
          }
        }).catch((error: BusinessError): void => {
          console.error(`自动恢复流程失败: ${error.message ?? '未知错误'}`);
        });
      }, this.tuning.refreshRetryDelayMs);
      return;
    }

    this.statusText = `${reason}；该电台暂时无法连接，可点击重试或切换其他频道`;
    this.notify();
    this.bluetooth.setPlaybackActive(false);
    if (this.context !== undefined) {
      this.backgroundTasks.stop(this.context).catch((error: BusinessError) => {
        console.error(`停止播放长时任务失败: ${error.message ?? '未知错误'}`);
      });
    }
  }

  private startWatchdog(player: media.AVPlayer): void {
    this.clearWatchdog();
    if (this.pausedByUser || this.audioInterrupted || this.waitingForBluetooth) {
      return;
    }
    this.watchdogTimer = setTimeout(() => {
      this.watchdogTimer = -1;
      if (this.player === player && !this.pausedByUser && !this.audioInterrupted &&
        !this.waitingForBluetooth && (this.buffering || !this.isPlaying)) {
        this.handlePlaybackFailure('直播连接或缓冲超时', player);
      }
    }, this.tuning.watchdogTimeoutMs);
  }

  private startFfmpegWatchdog(player: FfmpegAudioPlayer): void {
    this.clearWatchdog();
    if (this.pausedByUser || this.audioInterrupted || this.waitingForBluetooth) {
      return;
    }
    this.watchdogTimer = setTimeout(() => {
      this.watchdogTimer = -1;
      if (this.ffmpegPlayer === player && !this.pausedByUser && !this.audioInterrupted &&
        !this.waitingForBluetooth && (this.buffering || !this.isPlaying)) {
        this.handlePlaybackFailure('独立 FFmpeg 直播连接或缓冲超时');
      }
    }, this.tuning.watchdogTimeoutMs);
  }

  private clearWatchdog(): void {
    if (this.watchdogTimer >= 0) {
      clearTimeout(this.watchdogTimer);
      this.watchdogTimer = -1;
    }
  }

  private scheduleBufferHint(): void {
    if (this.bufferHintTimer >= 0) {
      return;
    }
    this.bufferHintTimer = setTimeout(() => {
      this.bufferHintTimer = -1;
      if (this.buffering && !this.isPlaying) {
        this.statusText = '直播缓冲中，正在优化起播';
        this.notify();
      }
    }, 800);
  }

  private clearBufferHint(): void {
    if (this.bufferHintTimer >= 0) {
      clearTimeout(this.bufferHintTimer);
      this.bufferHintTimer = -1;
    }
  }

  private scheduleBufferStallRecovery(player: media.AVPlayer): void {
    this.clearBufferStallRecovery();
    this.bufferStallTimer = setTimeout(() => {
      this.bufferStallTimer = -1;
      const liveHls = this.currentStation !== undefined &&
        isHlsPlaylistUrl(this.currentStation.streamUrl) &&
        FfmpegAudioPlayer.supports(this.currentStation.streamUrl);
      if (this.player === player &&
        shouldRecoverFromBufferStall(this.isPlaying, this.buffering, liveHls, 1500)) {
        this.handlePlaybackFailure('直播连续缓冲超过安全阈值', player);
      }
    }, 1500);
  }

  private clearBufferStallRecovery(): void {
    if (this.bufferStallTimer >= 0) {
      clearTimeout(this.bufferStallTimer);
      this.bufferStallTimer = -1;
    }
  }

  private clearRecoveryTimers(): void {
    this.clearWatchdog();
    this.clearBufferHint();
    this.clearBufferStallRecovery();
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  private prepareSessionInBackground(station: Station): void {
    this.ensureSession()
      .then((): Promise<void> => {
        return this.updateSessionMetadata(station);
      })
      .then((): Promise<void> => {
        return this.updateSessionPlaybackState(this.isPlaying);
      })
      .catch((error: BusinessError) => {
        console.error(`媒体会话初始化失败，不影响电台播放: ${error.message ?? '未知错误'}`);
      });
  }

  private prefetchOfficialStation(station: Station, requestId: number): void {
    this.radioCnResolver.resolve(station)
      .then((resolved: Station | undefined): void => {
        if (resolved === undefined || requestId !== this.playRequestId) {
          return;
        }
        const active = this.currentStation;
        if (active === undefined || active.id !== station.id) {
          return;
        }
        const activeUrl = active.streamUrl.trim();
        const refreshedLines: StreamLine[] = resolved.streamLines ?? [];
        const lines: StreamLine[] = [
          {
            id: 'active-stream',
            name: '当前在线',
            url: activeUrl,
            priority: 0,
            isStable: true
          }
        ];
        refreshedLines.forEach((line: StreamLine): void => {
          if (line.url.trim().length > 0 && line.url.trim() !== activeUrl) {
            lines.push({
              id: line.id,
              name: line.name,
              url: line.url.trim(),
              priority: lines.length + 1,
              isStable: line.isStable
            });
          }
        });
        this.currentStation = {
          id: active.id,
          name: active.name,
          streamUrl: activeUrl,
          streamLines: lines,
          activeLineIndex: 0,
          iconUrl: active.iconUrl.length > 0 ? active.iconUrl : resolved.iconUrl,
          tags: active.tags.length > 0 ? active.tags : resolved.tags,
          country: active.country,
          state: active.state,
          favorite: active.favorite
        };
        this.currentCandidates = buildPlaybackCandidates(this.currentStation);
        console.info(`官方备用线路已在后台就绪: ${Date.now() - this.playbackRequestedAt}ms`);
      })
      .catch((error: BusinessError) => {
        console.info(`官方线路后台刷新跳过: ${error.message ?? '未知错误'}`);
      });
  }

  private handleAudioInterrupt(event: audio.InterruptEvent): void {
    const eventType = event.eventType === audio.InterruptType.INTERRUPT_TYPE_BEGIN ? 'begin' : 'end';
    let hint: 'resume' | 'pause' | 'stop' | 'duck' | 'unduck' = 'unduck';
    if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
      hint = 'resume';
    } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE) {
      hint = 'pause';
    } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
      hint = 'stop';
    } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_DUCK) {
      hint = 'duck';
    }
    const action: AudioInterruptAction = audioInterruptAction(eventType, hint, this.pausedByUser);
    if (action === 'pause') {
      this.audioInterrupted = true;
      this.pauseForAudioInterruption().catch((error: BusinessError) => {
        console.error(`处理音频中断失败: ${error.message}`);
      });
    } else if (action === 'resume' && this.audioInterrupted) {
      this.resume('音频中断结束，继续播放').catch((error: BusinessError) => {
        console.error(`音频中断后恢复失败: ${error.message}`);
      });
    }
  }

  private async pauseForAudioInterruption(): Promise<void> {
    this.buffering = false;
    this.isPlaying = false;
    this.clearWatchdog();
    await this.releaseActivePlayers(false);
    await this.updateSessionPlaybackState(false);
    this.statusText = '音频暂时被其他应用占用，中断结束后自动续播';
    this.notify();
  }

  private async ensureSession(): Promise<void> {
    if (this.session !== undefined || this.context === undefined) {
      return;
    }
    const session = await avSession.createAVSession(this.context, SESSION_TAG, 'audio');
    this.session = session;
    session.setBackgroundPlayMode(avSession.BackgroundPlayMode.ENABLE_BACKGROUND_PLAY);
    session.on('play', () => {
      this.resume('从媒体控制继续播放');
    });
    session.on('pause', () => {
      this.pause('从媒体控制暂停', true);
    });
    session.on('stop', () => {
      this.stop();
    });
    await session.activate();
    this.sessionActive = true;
  }

  private async updateSessionMetadata(station: Station): Promise<void> {
    if (this.session === undefined) {
      return;
    }
    const metadata: avSession.AVMetadata = {
      assetId: station.id,
      title: station.name,
      artist: station.tags
    };
    const artwork = safeSessionArtwork(station.iconUrl);
    if (artwork.length > 0) {
      metadata.mediaImage = artwork;
    }
    try {
      await this.session.setAVMetadata(metadata);
    } catch (error) {
      const businessError = error as BusinessError;
      console.error(`锁屏媒体信息更新失败，不影响播放: ${businessError.message ?? '未知错误'}`);
    }
  }

  private async updateSessionPlaybackState(isPlaying: boolean): Promise<void> {
    if (this.session === undefined) {
      return;
    }
    if (sessionPlaybackMode(isPlaying) === 'playing') {
      if (!this.sessionActive) {
        await this.session.activate();
        this.sessionActive = true;
      }
      await this.session.setAVPlaybackState({
        state: avSession.PlaybackState.PLAYBACK_STATE_PLAY
      });
      return;
    }
    if (!this.sessionActive) {
      return;
    }
    await this.session.setAVPlaybackState({
      state: avSession.PlaybackState.PLAYBACK_STATE_STOP
    });
    await this.session.deactivate();
    this.sessionActive = false;
  }

  private async handleBluetoothLost(deviceId: string): Promise<void> {
    if (this.currentStation === undefined) {
      return;
    }
    if (!shouldStopForBluetoothDisconnect(
      this.settings.pauseOnBluetoothDisconnect,
      this.isPlaying,
      this.buffering,
      this.currentStation !== undefined
    )) {
      this.statusText = '蓝牙已断开，继续通过扬声器播放';
      this.notify();
      return;
    }
    await this.stop();
    this.stoppedForBluetoothDeviceId = deviceId;
    this.stoppedForBluetoothAt = Date.now();
    this.waitingForBluetooth = false;
    this.statusText = '蓝牙已断开，播放已停止';
    this.notify();
  }

  private async handleBluetoothConnected(deviceId: string, deviceName: string): Promise<void> {
    const existingBinding = findBluetoothBinding(this.settings.bluetoothBindings, deviceId);
    this.settings.bluetoothBindings = rememberBluetoothBinding(
      this.settings.bluetoothBindings,
      deviceId,
      deviceName.length > 0 ? deviceName : deviceId,
      Date.now()
    );
    const binding = findBluetoothBinding(this.settings.bluetoothBindings, deviceId);
    if (existingBinding === undefined && this.settings.autoPlayOnBluetoothConnect &&
      binding !== undefined) {
      binding.autoPlay = true;
    }
    this.notify();
    const activeBinding = findBluetoothBinding(this.settings.bluetoothBindings, deviceId);
    const boundStation = this.currentStation ?? this.defaultStation;
    if (activeBinding !== undefined && shouldStartBoundBluetoothPlayback(
      activeBinding.autoPlay,
      this.isPlaying,
      this.buffering,
      boundStation !== undefined
    ) && boundStation !== undefined) {
      this.statusText = `蓝牙设备 ${activeBinding.deviceName} 已连接，自动开始播放`;
      this.notify();
      await this.playStation(boundStation);
      return;
    }
    const withinResumeWindow = this.stoppedForBluetoothAt > 0 &&
      Date.now() - this.stoppedForBluetoothAt <= this.settings.resumeWindowMinutes * 60 * 1000;
    if (shouldResumeStoppedBluetooth(
      this.settings.autoResume,
      deviceId === this.stoppedForBluetoothDeviceId,
      withinResumeWindow,
      this.currentStation !== undefined
    )) {
      const station = this.currentStation;
      if (station !== undefined) {
        await this.playStation(station);
        this.statusText = `蓝牙设备 ${deviceId} 已重连，自动续播`;
        this.notify();
        return;
      }
    }
    if (this.waitingForBluetooth && this.settings.autoResume && this.currentStation !== undefined) {
      await this.resume(`蓝牙设备 ${deviceId} 已重连，自动续播`);
      return;
    }
    if (activeBinding !== undefined) {
      return;
    }
    const station = this.currentStation ?? this.defaultStation;
    if (!shouldAutoPlayOnBluetoothConnect(
      this.settings.autoPlayOnBluetoothConnect,
      this.isPlaying,
      this.buffering,
      station !== undefined
    ) || station === undefined) {
      return;
    }
    this.statusText = `蓝牙设备 ${deviceId} 已连接，自动开始播放`;
    this.notify();
    await this.playStation(station);
  }

  private async handleResumeWindowExpired(deviceId: string): Promise<void> {
    if (!this.waitingForBluetooth) {
      return;
    }
    this.waitingForBluetooth = false;
    if (this.context !== undefined) {
      await this.backgroundTasks.stop(this.context);
    }
    this.statusText =
      `蓝牙设备 ${deviceId} 超过 ${this.settings.resumeWindowMinutes} 分钟未重连`;
    this.notify();
  }

  private notify(): void {
    const snapshot = this.snapshot();
    this.listeners.forEach((listener: RadioStateListener) => {
      listener(snapshot);
    });
  }

  private shouldMonitorBluetooth(): boolean {
    return this.settings.autoResume ||
      this.settings.pauseOnBluetoothDisconnect ||
      this.settings.autoPlayOnBluetoothConnect;
  }
}
