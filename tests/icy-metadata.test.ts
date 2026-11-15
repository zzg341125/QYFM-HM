import assert from 'node:assert/strict';
import test from 'node:test';
import {
  HttpChunkDecoder,
  IcyMetadataStripper,
  inferAudioCodecFromUrl,
  isProgressiveAudioUrl,
  parseAudioCodec,
  parseAudioCodecFromHeaderText,
  parseHttpEndpoint,
  parseIcyMetaint,
  parseIcyMetaintFromHeaderText
} from '../entry/src/main/ets/utils/IcyMetadata.ts';

test('reads icy-metaint without depending on header casing', () => {
  assert.equal(parseIcyMetaint({ 'icy-metaint': '16000' }), 16000);
  assert.equal(parseIcyMetaint({ 'Icy-MetaData': '1', 'ICY-METAINT': '8192' }), 8192);
  assert.equal(parseIcyMetaint({ 'content-type': 'audio/mpeg' }), 0);
  assert.equal(parseIcyMetaintFromHeaderText('HTTP/1.1 200 OK\r\nIcy-Metaint: 16000\r\n'), 16000);
});

test('removes Icecast metadata split across network chunks', () => {
  const metaint = 4;
  const stream = new Uint8Array(28);
  stream.set([1, 2, 3, 4, 1], 0);
  stream.set(new Array<number>(16).fill(0), 5);
  stream.set([65, 66], 6);
  stream.set([5, 6, 7, 8, 0, 9, 10], 21);
  const stripper = new IcyMetadataStripper();
  stripper.configure(metaint);
  const first = stripper.strip(stream.slice(0, 9));
  const second = stripper.strip(stream.slice(9));
  assert.deepEqual(Array.from(first), [1, 2, 3, 4]);
  assert.deepEqual(Array.from(second), [5, 6, 7, 8, 9, 10]);
});

test('recognizes old MP3 and AAC links that may carry Icecast metadata', () => {
  assert.equal(isProgressiveAudioUrl('http://lhttp.qingting.fm/live/4915/64k.mp3'), true);
  assert.equal(isProgressiveAudioUrl('https://radio.example/live.MP3?token=1'), true);
  assert.equal(
    isProgressiveAudioUrl('https://video1.getstreamhosting.com:8292/stream?.mp3'),
    true
  );
  assert.equal(isProgressiveAudioUrl('https://radio.example/live.aac'), true);
  assert.equal(isProgressiveAudioUrl('https://radio.example/live.m3u8'), false);
});

test('parses legacy HTTP Icecast endpoints and chunked response bodies', () => {
  assert.deepEqual(
    parseHttpEndpoint('http://lhttp.qingting.fm:80/live/4915/64k.mp3?token=1'),
    {
      host: 'lhttp.qingting.fm',
      port: 80,
      path: '/live/4915/64k.mp3?token=1',
      hostHeader: 'lhttp.qingting.fm',
      secure: false
    }
  );
  assert.deepEqual(
    parseHttpEndpoint('https://lhttp.qtfm.cn/live/20500149/64k.mp3?token=1'),
    {
      host: 'lhttp.qtfm.cn',
      port: 443,
      path: '/live/20500149/64k.mp3?token=1',
      hostHeader: 'lhttp.qtfm.cn',
      secure: true
    }
  );
  const decoder = new HttpChunkDecoder();
  const first = decoder.push(new Uint8Array([
    0x34, 0x0d, 0x0a, 1, 2
  ]));
  const second = decoder.push(new Uint8Array([
    3, 4, 0x0d, 0x0a,
    0x33, 0x3b, 0x78, 0x3d, 0x31, 0x0d, 0x0a, 5, 6, 7, 0x0d, 0x0a,
    0x30, 0x0d, 0x0a, 0x0d, 0x0a
  ]));
  assert.deepEqual(Array.from(first), []);
  assert.deepEqual(Array.from(second), [1, 2, 3, 4, 5, 6, 7]);
  assert.equal(decoder.isEnded(), true);
});

test('recognizes the extensionless New Zealand AAC Icecast endpoint', () => {
  assert.equal(inferAudioCodecFromUrl('http://radiolive.nz936.com:8443/fm994'), undefined);
  assert.equal(isProgressiveAudioUrl('http://radiolive.nz936.com:8443/fm994'), true);
  assert.equal(isProgressiveAudioUrl('http://radiolive.nz936.com:8443/am936'), true);
  assert.equal(isProgressiveAudioUrl('https://example.com/live/index.m3u8'), false);
});

test('detects the decoder from the stream response instead of its URL suffix', () => {
  assert.equal(parseAudioCodec({ 'Content-Type': 'audio/aac' }), 'aac');
  assert.equal(parseAudioCodec({ 'content-type': 'audio/mpeg' }), 'mp3');
  assert.equal(parseAudioCodec({ 'content-type': 'application/octet-stream' }), undefined);
  assert.equal(
    parseAudioCodecFromHeaderText('HTTP/1.0 200 OK\r\nContent-Type: audio/aac\r\n'),
    'aac'
  );
  assert.equal(
    parseAudioCodecFromHeaderText('HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\n'),
    'mp3'
  );
});
