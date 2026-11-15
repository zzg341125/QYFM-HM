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
    'http://lhttp.qtfm.cn/live/4915/64k.mp3?app_id=web'
  );
});

test('migrates the retired NER host to its current official HLS entry', () => {
  assert.equal(
    migrateLegacyStreamUrl('https://cast.ner.gov.tw/1'),
    'https://wowza1.ner.gov.tw/TPFM/1/playlist.m3u8'
  );
  assert.equal(
    migrateLegacyStreamUrl('http://cast.ner.gov.tw/7/?source=legacy'),
    'https://wowza1.ner.gov.tw/TPFM/7/playlist.m3u8'
  );
  assert.equal(
    migrateLegacyStreamUrl(
      'https://wowza1.ner.gov.tw/TPFM/1/chunklist_w513979078.m3u8'
    ),
    'https://wowza1.ner.gov.tw/TPFM/1/playlist.m3u8'
  );
});

test('uses current HTTP HLS entries for Taiwan broadcasters', () => {
  assert.equal(
    migrateLegacyStreamUrl(
      'https://stream.ginnet.cloud/live0130lo-yfyo/_definst_/fm/chunklist_w999572124.m3u8'
    ),
    'http://stream.ginnet.cloud/live0130lo-yfyo/_definst_/fm/playlist.m3u8'
  );
  assert.equal(
    migrateLegacyStreamUrl(
      'https://flv.ccdntech.com/live/_definst_/mp4:vod117_Live/live1/chunklist_w872521607.m3u8'
    ),
    'http://flv.ccdntech.com/live/_definst_/mp4:vod117_Live/live1/chunklist.m3u8'
  );
  assert.equal(
    migrateLegacyStreamUrl(
      'https://streamak0138.akamaized.net/live0138lh-mbm9/_definst_/rti3/chunklist.m3u8'
    ),
    'http://streamak0138.akamaized.net/live0138lh-mbm9/_definst_/rti3/chunklist.m3u8'
  );
});

test('moves regional Revma links to the stable HTTP routing host', () => {
  assert.equal(
    migrateLegacyStreamUrl(
      'https://n36a-eu.rcs.revma.com/xpgtqc74hv8uv?rj-ttl=5&rj-tok=expired'
    ),
    'http://n13.rcs.revma.com/xpgtqc74hv8uv'
  );
  assert.equal(
    migrateLegacyStreamUrl(
      'https://n14a-eu.rcs.revma.com/e0tdah74hv8uv?rj-ttl=5&rj-tok=expired'
    ),
    'http://n13.rcs.revma.com/e0tdah74hv8uv'
  );
  assert.equal(
    migrateLegacyStreamUrl('https://n03-us1.rcs.revma.com/xpgtqc74hv8uv'),
    'http://n13.rcs.revma.com/xpgtqc74hv8uv'
  );
});

test('uses the generic HTTP transport for Qingting MP3 streams', () => {
  assert.equal(
    migrateLegacyStreamUrl('https://lhttp.qtfm.cn/live/20500149/64k.mp3'),
    'http://lhttp.qtfm.cn/live/20500149/64k.mp3'
  );
  assert.equal(
    migrateLegacyStreamUrl('https://lhttp-hw.qtfm.cn/live/1949/64k.mp3'),
    'http://lhttp-hw.qtfm.cn/live/1949/64k.mp3'
  );
  assert.equal(
    migrateLegacyStreamUrl('https://lhttp.qingting.fm/live/4919/64k.mp3'),
    'http://lhttp.qingting.fm/live/4919/64k.mp3'
  );
});

test('keeps unrelated radio URLs unchanged', () => {
  const url = 'https://radio.example/live/128.mp3';
  assert.equal(migrateLegacyStreamUrl(url), url);
});

test('uses the verified HTTP Icecast endpoint for the US Mandarin station', () => {
  assert.equal(
    migrateLegacyStreamUrl('https://video1.getstreamhosting.com:8292/stream?.mp3'),
    'http://video1.getstreamhosting.com:8292/stream?.mp3'
  );
});
