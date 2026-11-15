import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { media } from '@kit.MediaKit';
import { avSession } from '@kit.AVSessionKit';
import { audio } from '@kit.AudioKit';
import { AppSettings, createDefaultSettings, Station, StreamLine } from '../models/Station';
import { BackgroundTaskService } from './BackgroundTaskService';
import { BluetoothResumeCallbacks, BluetoothResumeManager } from './BluetoothResumeManager';
import { IcecastStreamRelay } from './IcecastStreamRelay';
import { RadioCnResolver } from './RadioCnResolver';
import { SilentAudioKeepAlive } from './SilentAudioKeepAlive';
import {
  audioInterruptAction,
  AudioInterruptAction,
  buildLivePlaybackTuning,
  buildPlaybackCandidates,
  PlaybackCandidate,
  LivePlaybackTuning,
  shouldAutoPlayOnBluetoothConnect,
  shouldResumeAfterForeground
} from '../utils/PlaybackRecovery';
import { migrateLegacyStreamUrl } from '../utils/StreamUrlRepair';
import { safeSessionArtwork } from '../utils/SessionArtwork';

export interface RadioSnapshot {
  currentStation: Station | undefined;
  state: string;
  isPlaying: boolean;
  waitingForBluetooth: boolean;
  statusText: string;
  diagnostics: string;
  sleepTimerMinutes: number;
  sleepTimerEndAt: number;
}

export type RadioStateListener = (snapshot: RadioSnapshot) => void;

const SESSION_TAG: string = 'QYFM_NATIVE_SESSION';
const LIVE_USER_AGENT: string = 'QYFM-HarmonyOS/1.0.19 (AVPlayer)';

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
  private icyRelay: IcecastStreamRelay | undefined = undefined;
  private session: avSession.AVSession | undefined = undefined;
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
  private retryTimer: number = -1;
  private watchdogTimer: number = -1;
  private retryCount: number = 0;
  private candidatePosition: number = 0;
  private playRequestId: number = 0;
  private currentCandidates: PlaybackCandidate[] = [];
  private buffering: boolean = false;
  private audioInterrupted: boolean = false;
  private tuning: LivePlaybackTuning = buildLivePlaybackTuning(true);
  private backgroundTasks: BackgroundTaskService = new BackgroundTaskService();
  private silentKeepAlive: SilentAudioKeepAlive = new SilentAudioKeepAlive();
  private radioCnResolver: RadioCnResolver = new RadioCnResolver();
  private bluetooth: BluetoothResumeManager;

  private constructor() {
    const callbacks: BluetoothResumeCallbacks = {
      onBluetoothLost: (deviceId: string): void => {
        this.handleBluetoothLost(deviceId);
      },
      onBluetoothRestored: (deviceId: string): void => {
        this.handleBluetoothRestored(deviceId);
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
    this.tuning = buildLivePlaybackTuning(settings.fastStart);
    this.bluetooth.setResumeWindowMinutes(settings.resumeWindowMinutes);
    if (this.shouldMonitorBluetooth()) {
      this.bluetooth.start();
    } else {
      this.bluetooth.stop();
      this.bluetooth.cancelPending();
      await this.silentKeepAlive.stop();
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
      sleepTimerEndAt: this.sleepTimerEndAt
    };
  }

  async playStation(station: Station): Promise<void> {
    const context = this.context;
    if (context === undefined) {
      this.statusText = '应用尚未完成初始化';
      this.notify();
      return;
    }
    const requestId = ++this.playRequestId;
    if (this.sleepTimer >= 0) {
      clearTimeout(this.sleepTimer);
      this.sleepTimer = -1;
      this.sleepTimerMinutes = 0;
      this.sleepTimerEndAt = 0;
    }
    this.waitingForBluetooth = false;
    this.pausedByUser = false;
    this.audioInterrupted = false;
    this.clearRecoveryTimers();
    this.retryCount = 0;
    this.candidatePosition = 0;
    this.tuning = buildLivePlaybackTuning(this.settings.fastStart);
    this.bluetooth.cancelPending();
    await this.silentKeepAlive.stop();
    this.isPlaying = false;
    this.statusText = `正在准备 ${station.name}`;
    this.notify();
    const migratedStation = this.migrateLegacyStation(station);
    const resolvedStation = await this.radioCnResolver.resolve(migratedStation);
    if (requestId !== this.playRequestId) {
      return;
    }
    const playableStation = resolvedStation ?? migratedStation;
    this.currentStation = playableStation;
    this.currentCandidates = buildPlaybackCandidates(playableStation);
    if (this.currentCandidates.length === 0) {
      this.statusText = '该电台暂无有效音频直播流';
      this.notify();
      return;
    }
    this.statusText =
      `正在连接 ${playableStation.name} · ${this.currentCandidates[0].name}`;
    this.notify();
    try {
      await this.ensureSession();
      await this.updateSessionMetadata(playableStation);
    } catch (error) {
      const sessionError = error as BusinessError;
      console.error(`媒体会话初始化失败，不影响电台播放: ${sessionError.message ?? '未知错误'}`);
    }
    try {
      await this.backgroundTasks.start(context);
      if (this.shouldMonitorBluetooth()) {
        this.bluetooth.setPlaybackActive(true);
      }
      await this.startCandidate(this.currentCandidates[0], false);
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
    const player = this.player;
    this.clearRecoveryTimers();
    if (player === undefined || (player.state !== 'paused' && player.state !== 'prepared')) {
      await this.playStation(this.currentStation);
      return;
    }
    try {
      this.waitingForBluetooth = false;
      this.pausedByUser = false;
      this.audioInterrupted = false;
      await this.silentKeepAlive.stop();
      await player.play();
      this.startWatchdog(player);
      this.statusText = reason;
      this.notify();
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
      await this.silentKeepAlive.stop();
      if (this.context !== undefined) {
        await this.backgroundTasks.stop(this.context);
      }
    }
    try {
      if (this.player !== undefined && this.player.state === 'playing') {
        await this.player.pause();
      }
    } catch (error) {
      const businessError = error as BusinessError;
      console.error(`暂停失败: ${businessError.message}`);
    }
    this.isPlaying = false;
    this.waitingForBluetooth = !manual && this.settings.autoResume;
    this.statusText = reason;
    this.notify();
  }

  async stop(): Promise<void> {
    this.playRequestId++;
    this.pausedByUser = true;
    this.audioInterrupted = false;
    this.clearRecoveryTimers();
    this.retryCount = 0;
    this.candidatePosition = 0;
    this.currentCandidates = [];
    this.bluetooth.cancelPending();
    this.bluetooth.setPlaybackActive(false);
    await this.silentKeepAlive.stop();
    if (this.sleepTimer >= 0) {
      clearTimeout(this.sleepTimer);
      this.sleepTimer = -1;
      this.sleepTimerMinutes = 0;
      this.sleepTimerEndAt = 0;
    }
    if (this.player !== undefined) {
      await this.player.release();
      this.player = undefined;
    }
    this.icyRelay?.destroy();
    this.icyRelay = undefined;
    if (this.context !== undefined) {
      await this.backgroundTasks.stop(this.context);
    }
    this.isPlaying = false;
    this.waitingForBluetooth = false;
    this.statusText = '已停止';
    this.notify();
  }

  async resumeIfPausedAfterForeground(): Promise<void> {
    if (this.pausedByUser || this.waitingForBluetooth || this.audioInterrupted ||
      this.currentStation === undefined) {
      return;
    }
    const player = this.player;
    const state = player === undefined ? 'idle' : player.state;
    if (!shouldResumeAfterForeground(state, this.pausedByUser, this.waitingForBluetooth, true)) {
      return;
    }
    if (state === 'paused' || state === 'prepared') {
      await this.resume('返回前台，继续播放');
      return;
    }
    this.statusText = '返回前台，正在恢复直播';
    await this.playStation(this.currentStation);
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
        this.pause('睡眠定时已结束', true);
      }, minutes * 60 * 1000);
      const end = new Date(this.sleepTimerEndAt);
      const hour = end.getHours().toString().padStart(2, '0');
      const minute = end.getMinutes().toString().padStart(2, '0');
      this.statusText = `${minutes} 分钟后于 ${hour}:${minute} 停止播放`;
    } else {
      this.sleepTimerEndAt = 0;
      this.statusText = '睡眠定时已关闭';
    }
    this.notify();
  }

  private async startCandidate(candidate: PlaybackCandidate, isRetry: boolean): Promise<void> {
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
    await this.updateSessionMetadata(nextStation);
    await this.replacePlayer(candidate);
    if (!isRetry) {
      this.statusText = `正在连接 ${station.name} · ${candidate.name}`;
      this.notify();
    }
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

  private async replacePlayer(candidate: PlaybackCandidate): Promise<void> {
    console.info(`准备播放线路: ${candidate.url}`);
    this.clearRecoveryTimers();
    this.buffering = true;
    const oldPlayer = this.player;
    const oldRelay = this.icyRelay;
    this.player = undefined;
    this.icyRelay = undefined;
    if (oldPlayer !== undefined) {
      try {
        await oldPlayer.release();
      } catch (error) {
        const businessError = error as BusinessError;
        console.error(`旧播放器释放失败: ${businessError.message}`);
      }
    }
    oldRelay?.destroy();

    const player = await media.createAVPlayer();
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
        this.buffering = true;
        this.statusText = '直播缓冲中，正在优化起播';
        this.startWatchdog(player);
        this.notify();
      } else if (infoType === media.BufferingInfoType.BUFFERING_END) {
        this.buffering = false;
        this.clearWatchdog();
      }
    });
    player.on('audioInterrupt', (event: audio.InterruptEvent) => {
      if (this.player !== player) {
        return;
      }
      this.handleAudioInterrupt(event);
    });
    if (this.settings.icecastCompatibility && IcecastStreamRelay.supports(candidate.url) &&
      this.context !== undefined) {
      const relay = new IcecastStreamRelay();
      try {
        const relaySource = await relay.prepare(
          this.context,
          candidate.url,
          this.settings.fastStart
        );
        if (relaySource !== undefined && this.player === player) {
          this.icyRelay = relay;
          player.dataSrc = relaySource;
        } else {
          relay.destroy();
          await this.setUrlMediaSource(player, candidate.url);
        }
      } catch (error) {
        relay.destroy();
        const businessError = error as BusinessError;
        console.error(`Icecast 兼容模式失败，改用系统直连: ${businessError.message ?? '未知错误'}`);
        await this.setUrlMediaSource(player, candidate.url);
      }
    } else {
      await this.setUrlMediaSource(player, candidate.url);
    }
    this.startWatchdog(player);
  }

  private async setUrlMediaSource(player: media.AVPlayer, url: string): Promise<void> {
    const headers: Record<string, string> = {
      'User-Agent': LIVE_USER_AGENT,
      'Icy-MetaData': '1',
      'Accept': '*/*'
    };
    const source = media.createMediaSourceWithUrl(url, headers);
    await player.setMediaSource(source);
  }

  private async handlePlayerState(player: media.AVPlayer, state: string): Promise<void> {
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
      this.buffering = false;
      this.retryCount = 0;
      this.isPlaying = true;
      this.waitingForBluetooth = false;
      this.statusText = this.currentStation?.name ?? '正在播放';
      await this.updateSessionPlaybackState(true);
      this.notify();
    } else if (state === 'paused') {
      this.isPlaying = false;
      this.buffering = false;
      if (!this.waitingForBluetooth) {
        this.statusText = this.audioInterrupted ? '音频暂时被其他应用占用' : '已暂停';
      }
      await this.updateSessionPlaybackState(false);
      this.notify();
    } else if (state === 'completed' || state === 'stopped') {
      this.isPlaying = false;
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

  private handlePlaybackFailure(reason: string, failedPlayer?: media.AVPlayer): void {
    if (failedPlayer !== undefined && this.player !== failedPlayer) {
      return;
    }
    if (this.pausedByUser || this.waitingForBluetooth || this.audioInterrupted ||
      this.currentStation === undefined || this.currentCandidates.length === 0) {
      this.notify();
      return;
    }
    this.clearRecoveryTimers();
    this.buffering = false;
    this.isPlaying = false;
    const brokenPlayer = failedPlayer ?? this.player;
    if (brokenPlayer !== undefined && this.player === brokenPlayer) {
      this.player = undefined;
      brokenPlayer.release().catch((error: BusinessError) => {
        console.error(`释放故障播放器失败: ${error.message ?? '未知错误'}`);
      });
    }
    this.icyRelay?.destroy();
    this.icyRelay = undefined;
    this.updateSessionPlaybackState(false).catch((error: BusinessError) => {
      console.error(`更新媒体暂停状态失败: ${error.message}`);
    });

    const nextPosition = this.candidatePosition + 1;
    if (nextPosition < this.currentCandidates.length) {
      this.candidatePosition = nextPosition;
      const next = this.currentCandidates[nextPosition];
      this.statusText = `正在无感切换备用线路：${next.name}`;
      this.notify();
      this.startCandidate(next, true).catch((error: BusinessError) => {
        this.handlePlaybackFailure(`备用线路连接失败：${error.message ?? '未知错误'}`);
      });
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
        this.startCandidate(current, true).catch((error: BusinessError) => {
          this.handlePlaybackFailure(`自动恢复失败：${error.message ?? '未知错误'}`);
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

  private clearWatchdog(): void {
    if (this.watchdogTimer >= 0) {
      clearTimeout(this.watchdogTimer);
      this.watchdogTimer = -1;
    }
  }

  private clearRecoveryTimers(): void {
    this.clearWatchdog();
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
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
    const player = this.player;
    try {
      if (player !== undefined && player.state === 'playing') {
        await player.pause();
      }
    } catch (error) {
      const businessError = error as BusinessError;
      console.error(`音频中断暂停失败: ${businessError.message}`);
    }
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
    await this.session.setAVPlaybackState({
      state: isPlaying
        ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
        : avSession.PlaybackState.PLAYBACK_STATE_PAUSE
    });
  }

  private async handleBluetoothLost(deviceId: string): Promise<void> {
    if (this.currentStation === undefined || !this.isPlaying) {
      return;
    }
    if (!this.settings.pauseOnBluetoothDisconnect) {
      this.statusText = '蓝牙已断开，继续通过扬声器播放';
      this.notify();
      return;
    }
    await this.pause('蓝牙已断开，已自动暂停', false);
    if (this.settings.autoResume) {
      await this.silentKeepAlive.start();
      this.waitingForBluetooth = true;
      this.statusText =
        `蓝牙已断开，${this.settings.resumeWindowMinutes} 分钟内重连将自动续播`;
    } else {
      this.waitingForBluetooth = false;
      this.statusText = '蓝牙已断开，已自动暂停';
    }
    this.notify();
  }

  private async handleBluetoothRestored(deviceId: string): Promise<void> {
    if (this.waitingForBluetooth && this.settings.autoResume && this.currentStation !== undefined) {
      await this.resume(`蓝牙设备 ${deviceId} 已重连，自动续播`);
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
    await this.silentKeepAlive.stop();
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
