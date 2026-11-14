import assert from 'node:assert/strict';
import test from 'node:test';
import {
  formatSleepTimerEnd,
  normalizeResumeWindowMinutes
} from '../entry/src/main/ets/utils/TimeSettings.ts';

test('shows the exact sleep timer stop time across midnight', () => {
  assert.equal(
    formatSleepTimerEnd(new Date(2026, 10, 14, 23, 50), 30),
    '将于 00:20 停止播放'
  );
});

test('keeps the Bluetooth resume window inside safe bounds', () => {
  assert.equal(normalizeResumeWindowMinutes(0), 5);
  assert.equal(normalizeResumeWindowMinutes(240), 240);
  assert.equal(normalizeResumeWindowMinutes(5000), 1440);
});
