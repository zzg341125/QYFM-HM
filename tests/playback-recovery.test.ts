import assert from 'node:assert/strict';
import test from 'node:test';
import {
  buildLivePlaybackTuning,
  recoveryDelayMs,
  shouldResumeAfterForeground
} from '../entry/src/main/ets/utils/PlaybackRecovery.ts';

test('backs off repeated live stream reconnects without retrying forever at one second', () => {
  assert.deepEqual(
    [0, 1, 2, 3, 4, 5, 6].map(recoveryDelayMs),
    [1000, 2000, 4000, 8000, 16000, 30000, 30000]
  );
});

test('uses a stable HLS restart waterline and a larger restart threshold', () => {
  assert.deepEqual(buildLivePlaybackTuning(true, false), {
    preferredBufferDuration: 8,
    preferredBufferDurationForPlaying: 1,
    thresholdForAutoQuickPlay: 4
  });
  assert.deepEqual(buildLivePlaybackTuning(false, true), {
    preferredBufferDuration: 30,
    preferredBufferDurationForPlaying: 3,
    thresholdForAutoQuickPlay: 6
  });
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
