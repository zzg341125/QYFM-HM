import assert from 'node:assert/strict';
import test from 'node:test';
import {
  PlaybackRecoveryGate,
  buildLivePlaybackTuning,
  buildPlaybackCandidates,
  audioInterruptAction,
  sessionPlaybackMode,
  shouldAutoPlayOnBluetoothConnect,
  shouldStopForBluetoothDisconnect,
  shouldResumeStoppedBluetooth,
  shouldResumeAfterForeground,
  shouldRecoverFromBufferStall
} from '../entry/src/main/ets/utils/PlaybackRecovery.ts';

test('uses fast start with segment-safe buffering and watchdog timing', () => {
  assert.deepEqual(buildLivePlaybackTuning(true), {
    preferredBufferDuration: 30,
    preferredBufferDurationForPlaying: 0.25,
    thresholdForAutoQuickPlay: 2.25,
    watchdogTimeoutMs: 15000,
    maxAutoRetries: 2,
    refreshRetryDelayMs: 600
  });
  assert.deepEqual(buildLivePlaybackTuning(false), {
    preferredBufferDuration: 30,
    preferredBufferDurationForPlaying: 0.8,
    thresholdForAutoQuickPlay: 2.8,
    watchdogTimeoutMs: 15000,
    maxAutoRetries: 2,
    refreshRetryDelayMs: 600
  });
});

test('fails over from the active LX-FM line through later backup lines only', () => {
  const candidates = buildPlaybackCandidates({
    streamUrl: 'https://primary.example/live.m3u8',
    activeLineIndex: 1,
    streamLines: [
      { id: 'primary', name: '官方专线', url: 'https://primary.example/live.m3u8' },
      { id: 'backup-a', name: '公网备用', url: 'https://backup-a.example/live.mp3' },
      { id: 'backup-b', name: '第三线路', url: 'https://backup-b.example/live.m3u8' }
    ]
  });

  assert.deepEqual(candidates.map((candidate) => candidate.url), [
    'https://backup-a.example/live.mp3',
    'https://backup-b.example/live.m3u8'
  ]);
  assert.deepEqual(candidates.map((candidate) => candidate.lineIndex), [1, 2]);
});

test('uses the single stream URL when an older station has no explicit lines', () => {
  assert.deepEqual(
    buildPlaybackCandidates({
      streamUrl: 'https://legacy.example/live',
      activeLineIndex: 0,
      streamLines: []
    }),
    [{ url: 'https://legacy.example/live', lineIndex: 0, name: '默认主线' }]
  );
});

test('resumes after a temporary audio interruption but not after a user pause', () => {
  assert.equal(audioInterruptAction('begin', 'pause', false), 'pause');
  assert.equal(audioInterruptAction('begin', 'stop', false), 'pause');
  assert.equal(audioInterruptAction('end', 'resume', false), 'resume');
  assert.equal(audioInterruptAction('end', 'resume', true), 'none');
  assert.equal(audioInterruptAction('begin', 'pause', true), 'none');
});

test('resumes an interrupted live stream on foreground but respects manual pause', () => {
  assert.equal(shouldResumeAfterForeground('paused', false, false, true), true);
  assert.equal(shouldResumeAfterForeground('prepared', false, false, true), true);
  assert.equal(shouldResumeAfterForeground('error', false, false, true), true);
  assert.equal(shouldResumeAfterForeground('idle', false, false, true), true);
  assert.equal(shouldResumeAfterForeground('playing', false, false, true), false);
  assert.equal(shouldResumeAfterForeground('paused', true, false, true), false);
  assert.equal(shouldResumeAfterForeground('paused', false, true, true), false);
  assert.equal(shouldResumeAfterForeground('paused', false, false, false), false);
});

test('starts the remembered station on Bluetooth connect only when playback is idle', () => {
  assert.equal(shouldAutoPlayOnBluetoothConnect(true, false, false, true), true);
  assert.equal(shouldAutoPlayOnBluetoothConnect(false, false, false, true), false);
  assert.equal(shouldAutoPlayOnBluetoothConnect(true, true, false, true), false);
  assert.equal(shouldAutoPlayOnBluetoothConnect(true, false, true, true), false);
  assert.equal(shouldAutoPlayOnBluetoothConnect(true, false, false, false), false);
});

test('allows only one playback recovery transition at a time', async () => {
  const gate = new PlaybackRecoveryGate();
  let finishFirst: (() => void) | undefined = undefined;
  let secondRan = false;
  let idleResolved = false;
  const first = gate.run(async (): Promise<void> => {
    await new Promise<void>((resolve: () => void): void => {
      finishFirst = resolve;
    });
  });
  const second = await gate.run(async (): Promise<void> => {
    secondRan = true;
  });

  assert.equal(second, false);
  assert.equal(secondRan, false);
  assert.equal(gate.active, true);
  const idle = gate.waitUntilIdle().then((): void => {
    idleResolved = true;
  });
  assert.equal(idleResolved, false);
  finishFirst?.();
  assert.equal(await first, true);
  await idle;
  assert.equal(gate.active, false);
  assert.equal(idleResolved, true);
});

test('hides media controls instead of publishing a paused lock-screen state', () => {
  assert.equal(sessionPlaybackMode(true), 'playing');
  assert.equal(sessionPlaybackMode(false), 'hidden');
});

test('stops playback immediately when the configured Bluetooth output disconnects', () => {
  assert.equal(shouldStopForBluetoothDisconnect(true, true, false, true), true);
  assert.equal(shouldStopForBluetoothDisconnect(true, false, true, true), true);
  assert.equal(shouldStopForBluetoothDisconnect(false, true, false, true), false);
  assert.equal(shouldStopForBluetoothDisconnect(true, false, false, true), false);
  assert.equal(shouldStopForBluetoothDisconnect(true, true, false, false), false);
});

test('resumes a Bluetooth-stopped station only for the same device inside its window', () => {
  assert.equal(shouldResumeStoppedBluetooth(true, true, true, true), true);
  assert.equal(shouldResumeStoppedBluetooth(false, true, true, true), false);
  assert.equal(shouldResumeStoppedBluetooth(true, false, true, true), false);
  assert.equal(shouldResumeStoppedBluetooth(true, true, false, true), false);
  assert.equal(shouldResumeStoppedBluetooth(true, true, true, false), false);
});

test('falls back only when a live stream remains buffering beyond the grace period', () => {
  assert.equal(shouldRecoverFromBufferStall(true, true, 1499), false);
  assert.equal(shouldRecoverFromBufferStall(true, true, 1500), true);
  assert.equal(shouldRecoverFromBufferStall(false, true, 5000), false);
  assert.equal(shouldRecoverFromBufferStall(true, false, 5000), false);
});
