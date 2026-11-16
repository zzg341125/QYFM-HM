import assert from 'node:assert/strict';
import test from 'node:test';
import {
  shouldPrimeDecoder,
  shouldReconnectAfterPause
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
