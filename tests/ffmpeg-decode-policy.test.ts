import assert from 'node:assert/strict';
import test from 'node:test';
import {
  pcmStartWatermark,
  pcmQueueDurationSeconds,
  shouldPrimeDecoder,
  shouldReconnectAfterPause,
  shouldStartPcmRenderer
} from '../entry/src/main/ets/utils/FfmpegDecodePolicy.ts';

test('primes only the first small compressed block on the UI thread', () => {
  assert.equal(shouldPrimeDecoder(true, 1400), true);
  assert.equal(shouldPrimeDecoder(true, 4096), true);
  assert.equal(shouldPrimeDecoder(true, 4097), false);
  assert.equal(shouldPrimeDecoder(false, 1400), false);
});

test('reconnects the live FFmpeg stream instead of resuming stale pause buffers', () => {
  assert.equal(shouldReconnectAfterPause(true), true);
  assert.equal(shouldReconnectAfterPause(false), true);
});

test('starts PCM output only after the configured live jitter waterline', () => {
  assert.equal(pcmStartWatermark(true), 96000);
  assert.equal(pcmStartWatermark(false), 230400);
  assert.equal(pcmStartWatermark(true, true), 2304000);
  assert.equal(pcmStartWatermark(false, true), 2304000);
  assert.equal(shouldStartPcmRenderer(true, 95999), false);
  assert.equal(shouldStartPcmRenderer(true, 96000), true);
  assert.equal(shouldStartPcmRenderer(true, 2303999, true), false);
  assert.equal(shouldStartPcmRenderer(true, 2304000, true), true);
  assert.equal(shouldStartPcmRenderer(false, 230399), false);
  assert.equal(shouldStartPcmRenderer(false, 230400), true);
});

test('keeps a full seven-second HLS segment without discarding most of it', () => {
  assert.equal(pcmQueueDurationSeconds(false), 3);
  assert.equal(pcmQueueDurationSeconds(true), 12);
});
