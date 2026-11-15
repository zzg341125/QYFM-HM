import assert from 'node:assert/strict';
import test from 'node:test';
import { migrateLegacyStreamUrl } from '../entry/src/main/ets/utils/StreamUrlRepair.ts';

test('migrates retired NZ 936 stream hosts without changing the channel path', () => {
  assert.equal(
    migrateLegacyStreamUrl('http://radio.936.nz:8443/am936'),
    'http://radiolive.nz936.com:8443/am936'
  );
  assert.equal(
    migrateLegacyStreamUrl('https://radio.936.nz:8443/fm994'),
    'http://radiolive.nz936.com:8443/fm994'
  );
});

test('keeps unrelated radio URLs unchanged', () => {
  const url = 'https://lhttp.qtfm.cn/live/1260/64k.mp3';
  assert.equal(migrateLegacyStreamUrl(url), url);
});
