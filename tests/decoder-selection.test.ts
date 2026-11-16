import assert from 'node:assert/strict';
import test from 'node:test';
import {
  buildDecoderAttemptOrder,
  canFallbackToFfmpeg,
  selectPrimaryDecoderEngine
} from '../entry/src/main/ets/utils/DecoderSelection.ts';

test('uses the native decoder for ordinary progressive and HLS radio', () => {
  assert.equal(selectPrimaryDecoderEngine('http://lhttp.qingting.fm/live/4915/64k.mp3'), 'native');
  assert.equal(selectPrimaryDecoderEngine('http://radiolive.nz936.com:8443/fm994'), 'native');
  assert.equal(selectPrimaryDecoderEngine('http://stream.ginnet.cloud/live/fm/playlist.m3u8'), 'native');
});

test('uses the managed FFmpeg reader only for the known incompatible NER host', () => {
  assert.equal(
    selectPrimaryDecoderEngine('https://wowza1.ner.gov.tw/TPFM/1/playlist.m3u8'),
    'ffmpeg'
  );
});

test('falls back to FFmpeg after a native decoder failure only for supported audio', () => {
  assert.equal(canFallbackToFfmpeg(true), true);
  assert.equal(canFallbackToFfmpeg(false), false);
});

test('tries the opposite decoder once on the same line', () => {
  assert.deepEqual(
    buildDecoderAttemptOrder('http://lhttp.qingting.fm/live/4915/64k.mp3', true),
    ['native', 'ffmpeg']
  );
  assert.deepEqual(
    buildDecoderAttemptOrder('https://wowza1.ner.gov.tw/TPFM/1/playlist.m3u8', true),
    ['ffmpeg', 'native']
  );
});

test('does not schedule an FFmpeg fallback for unsupported input', () => {
  assert.deepEqual(
    buildDecoderAttemptOrder('https://example.com/unsupported.bin', false),
    ['native']
  );
});
