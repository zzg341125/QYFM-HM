export interface LivePlaybackTuning {
  preferredBufferDuration: number;
  preferredBufferDurationForPlaying: number;
  thresholdForAutoQuickPlay: number;
}

export function recoveryDelayMs(attempt: number): number {
  if (attempt <= 0) {
    return 1000;
  }
  return Math.min(30000, 1000 * Math.pow(2, attempt));
}

export function buildLivePlaybackTuning(fastStart: boolean, largeBuffer: boolean): LivePlaybackTuning {
  const startWaterline = fastStart ? 3 : 5;
  return {
    preferredBufferDuration: largeBuffer ? 45 : 20,
    preferredBufferDurationForPlaying: startWaterline,
    thresholdForAutoQuickPlay: startWaterline + 4
  };
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
