export interface LivePlaybackTuning {
  preferredBufferDuration: number;
  preferredBufferDurationForPlaying: number;
  thresholdForAutoQuickPlay: number;
  watchdogTimeoutMs: number;
  maxAutoRetries: number;
  refreshRetryDelayMs: number;
}

export interface PlaybackLineSource {
  id?: string;
  name?: string;
  url: string;
}

export interface PlaybackStationSource {
  streamUrl: string;
  streamLines?: PlaybackLineSource[];
  activeLineIndex?: number;
}

export interface PlaybackCandidate {
  url: string;
  lineIndex: number;
  name: string;
}

export class PlaybackRecoveryGate {
  private running: boolean = false;
  private idleResolvers: Array<() => void> = [];

  get active(): boolean {
    return this.running;
  }

  waitUntilIdle(): Promise<void> {
    if (!this.running) {
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void): void => {
      this.idleResolvers.push(resolve);
    });
  }

  async run(operation: () => Promise<void>): Promise<boolean> {
    if (this.running) {
      return false;
    }
    this.running = true;
    try {
      await operation();
      return true;
    } finally {
      this.running = false;
      const resolvers = this.idleResolvers;
      this.idleResolvers = [];
      resolvers.forEach((resolve: () => void): void => {
        resolve();
      });
    }
  }
}

export function buildLivePlaybackTuning(fastStart: boolean): LivePlaybackTuning {
  const startWaterline = fastStart ? 0.25 : 0.8;
  return {
    preferredBufferDuration: 30,
    preferredBufferDurationForPlaying: startWaterline,
    thresholdForAutoQuickPlay: startWaterline + 2,
    watchdogTimeoutMs: 15000,
    maxAutoRetries: 2,
    refreshRetryDelayMs: 600
  };
}

export function buildPlaybackCandidates(station: PlaybackStationSource): PlaybackCandidate[] {
  const lines = Array.isArray(station.streamLines) ? station.streamLines : [];
  if (lines.length === 0) {
    const fallbackUrl = station.streamUrl.trim();
    return fallbackUrl.length === 0
      ? []
      : [{ url: fallbackUrl, lineIndex: 0, name: '默认主线' }];
  }
  const requestedIndex = station.activeLineIndex ?? 0;
  const activeIndex = Math.max(0, Math.min(requestedIndex, lines.length - 1));
  const seen = new Set<string>();
  const candidates: PlaybackCandidate[] = [];
  for (let index = activeIndex; index < lines.length; index++) {
    const line = lines[index];
    const url = typeof line.url === 'string' ? line.url.trim() : '';
    if (url.length === 0 || seen.has(url)) {
      continue;
    }
    seen.add(url);
    const name = typeof line.name === 'string' && line.name.trim().length > 0
      ? line.name.trim()
      : `线路 ${index + 1}`;
    candidates.push({ url: url, lineIndex: index, name: name });
  }
  return candidates;
}

export type AudioInterruptAction = 'pause' | 'resume' | 'none';

export function audioInterruptAction(
  eventType: 'begin' | 'end',
  hint: 'resume' | 'pause' | 'stop' | 'duck' | 'unduck',
  pausedByUser: boolean
): AudioInterruptAction {
  if (pausedByUser) {
    return 'none';
  }
  if (eventType === 'begin' && (hint === 'pause' || hint === 'stop')) {
    return 'pause';
  }
  if (eventType === 'end' && hint === 'resume') {
    return 'resume';
  }
  return 'none';
}

export function shouldResumeAfterForeground(
  playerState: string,
  pausedByUser: boolean,
  waitingForBluetooth: boolean,
  hasStation: boolean
): boolean {
  if (pausedByUser || waitingForBluetooth || !hasStation || playerState === 'playing') {
    return false;
  }
  return playerState === 'paused' ||
    playerState === 'prepared' ||
    playerState === 'error' ||
    playerState === 'stopped' ||
    playerState === 'completed' ||
    playerState === 'idle';
}

export function shouldAutoPlayOnBluetoothConnect(
  enabled: boolean,
  isPlaying: boolean,
  buffering: boolean,
  hasStation: boolean
): boolean {
  return enabled && !isPlaying && !buffering && hasStation;
}

export function shouldStopForBluetoothDisconnect(
  enabled: boolean,
  isPlaying: boolean,
  buffering: boolean,
  hasStation: boolean
): boolean {
  return enabled && (isPlaying || buffering) && hasStation;
}

export function shouldResumeStoppedBluetooth(
  enabled: boolean,
  sameDevice: boolean,
  insideWindow: boolean,
  hasStation: boolean
): boolean {
  return enabled && sameDevice && insideWindow && hasStation;
}

export type SessionPlaybackMode = 'playing' | 'hidden';

export function sessionPlaybackMode(isPlaying: boolean): SessionPlaybackMode {
  return isPlaying ? 'playing' : 'hidden';
}

export function shouldRecoverFromBufferStall(
  isPlaying: boolean,
  buffering: boolean,
  bufferingMilliseconds: number
): boolean {
  return isPlaying && buffering && bufferingMilliseconds >= 1500;
}
