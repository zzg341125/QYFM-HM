import assert from 'node:assert/strict';
import test from 'node:test';
import {
  hlsRequestReferer,
  isHlsPlaylistUrl,
  parseHlsMediaPlaylist,
  parseHlsVariantUrl,
  resolveHlsUrl,
  shouldUseManagedHlsReader,
  stripLeadingId3
} from '../entry/src/main/ets/utils/HlsPlaylist.ts';

test('resolves relative HLS playlist and segment references', () => {
  assert.equal(
    resolveHlsUrl(
      'https://wowza1.ner.gov.tw/TPFM/1/playlist.m3u8',
      'chunklist_w1.m3u8'
    ),
    'https://wowza1.ner.gov.tw/TPFM/1/chunklist_w1.m3u8'
  );
  assert.equal(
    resolveHlsUrl(
      'https://wowza1.ner.gov.tw/TPFM/1/chunklist.m3u8',
      '../2/media_w1.aac'
    ),
    'https://wowza1.ner.gov.tw/TPFM/2/media_w1.aac'
  );
  assert.equal(
    resolveHlsUrl('https://example.com/live/index.m3u8', '/audio/live.aac?token=1'),
    'https://example.com/audio/live.aac?token=1'
  );
});

test('reads the current Wowza variant and its rolling media segments', () => {
  const master = [
    '#EXTM3U',
    '#EXT-X-STREAM-INF:BANDWIDTH=136443,CODECS="mp4a.40.2"',
    'chunklist_w513979078.m3u8'
  ].join('\n');
  assert.equal(
    parseHlsVariantUrl(
      master,
      'https://wowza1.ner.gov.tw/TPFM/1/playlist.m3u8'
    ),
    'https://wowza1.ner.gov.tw/TPFM/1/chunklist_w513979078.m3u8'
  );
  const media = [
    '#EXTM3U',
    '#EXT-X-TARGETDURATION:3',
    '#EXTINF:2.019,',
    'media_w1_1.aac',
    '#EXTINF:2.021,',
    'media_w1_2.aac'
  ].join('\n');
  assert.deepEqual(
    parseHlsMediaPlaylist(
      media,
      'https://wowza1.ner.gov.tw/TPFM/1/chunklist_w1.m3u8'
    ),
    {
      segments: [
        'https://wowza1.ner.gov.tw/TPFM/1/media_w1_1.aac',
        'https://wowza1.ner.gov.tw/TPFM/1/media_w1_2.aac'
      ],
      targetDurationSeconds: 3
    }
  );
});

test('routes verified Taiwan AAC HLS hosts through the low-latency FFmpeg reader', () => {
  assert.equal(isHlsPlaylistUrl('https://example.com/live/index.m3u8?token=1'), true);
  assert.equal(isHlsPlaylistUrl('https://example.com/live/audio.aac'), false);
  assert.equal(
    shouldUseManagedHlsReader('https://wowza1.ner.gov.tw/TPFM/1/playlist.m3u8'),
    true
  );
  assert.equal(
    shouldUseManagedHlsReader('http://stream.ginnet.cloud/live/fm/playlist.m3u8'),
    true
  );
  assert.equal(
    shouldUseManagedHlsReader(
      'http://flv.ccdntech.com/live/_definst_/mp4:vod117_Live/live1/chunklist.m3u8'
    ),
    true
  );
  assert.equal(
    shouldUseManagedHlsReader(
      'http://streamak0138.akamaized.net/live0138lh-mbm9/_definst_/rti3/chunklist.m3u8'
    ),
    true
  );
});

test('routes seven-second Ximalaya AAC HLS playlists through the managed reader', () => {
  assert.equal(
    shouldUseManagedHlsReader('http://live.xmcdn.com/live/2628/64.m3u8'),
    true
  );
  assert.equal(
    shouldUseManagedHlsReader('http://live.xmcdn.com:80/live/2628/64.m3u8'),
    true
  );
  assert.equal(
    shouldUseManagedHlsReader('http://live.ximalaya.com/radio-first-page-app/live/151/64.m3u8'),
    true
  );
  assert.equal(
    shouldUseManagedHlsReader('http://live.ximalaya.com:80/radio-first-page-app/live/151/64.m3u8'),
    true
  );
});

test('removes the per-segment ID3 header before AAC decoding', () => {
  const segment = new Uint8Array(20);
  segment.set([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05], 0);
  segment.set([1, 2, 3, 4, 5], 10);
  segment.set([0xff, 0xf1, 0x50, 0x80, 0x01], 15);
  assert.deepEqual(Array.from(stripLeadingId3(segment)), [0xff, 0xf1, 0x50, 0x80, 0x01]);
});

test('uses the playlist as Referer when fetching protected AAC segments', () => {
  const master = 'https://wowza1.ner.gov.tw/TPFM/1/playlist.m3u8';
  const media = 'https://wowza1.ner.gov.tw/TPFM/1/chunklist_w1.m3u8';
  assert.equal(hlsRequestReferer('playlist', master, media), master);
  assert.equal(hlsRequestReferer('segment', master, media), media);
});
