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

test('keeps B3 on its continuous MP3 stream for Icecast cleanup', () => {
  assert.equal(
    migrateLegacyStreamUrl('http://lhttp.qingting.fm/live/4915/64k.mp3'),
    'http://lhttp.qingting.fm/live/4915/64k.mp3'
  );
  assert.equal(
    migrateLegacyStreamUrl('https://lhttp.qtfm.cn/live/4915/64k.mp3?app_id=web'),
    'https://lhttp.qtfm.cn/live/4915/64k.mp3?app_id=web'
  );
});

test('keeps unrelated radio URLs unchanged', () => {
  const url = 'https://lhttp.qtfm.cn/live/1260/64k.mp3';
  assert.equal(migrateLegacyStreamUrl(url), url);
});

test('uses the verified HTTP Icecast endpoint for the US Mandarin station', () => {
  assert.equal(
    migrateLegacyStreamUrl('https://video1.getstreamhosting.com:8292/stream?.mp3'),
    'http://video1.getstreamhosting.com:8292/stream?.mp3'
  );
});
