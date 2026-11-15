import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

test('allows cleartext radio streams required by legacy HTTP stations', () => {
  const moduleConfig = readFileSync(
    new URL('../entry/src/main/module.json5', import.meta.url),
    'utf8'
  );

  assert.match(moduleConfig, /ohos\.network\.security\.policy/);
  assert.match(moduleConfig, /\\?"cleartextTraffic\\?"\s*:\s*true/);
});
