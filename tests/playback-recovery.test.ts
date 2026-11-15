import assert from 'node:assert/strict';
import test from 'node:test';
import {
  buildLivePlaybackTuning,
  buildPlaybackCandidates,
  audioInterruptAction,
  shouldResumeAfterForeground
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
