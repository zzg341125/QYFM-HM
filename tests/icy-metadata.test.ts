import assert from 'node:assert/strict';
import test from 'node:test';
import {
  IcyMetadataStripper,
  isProgressiveMp3Url,
  parseIcyMetaint
} from '../entry/src/main/ets/utils/IcyMetadata.ts';

test('reads icy-metaint without depending on header casing', () => {
  assert.equal(parseIcyMetaint({ 'icy-metaint': '16000' }), 16000);
  assert.equal(parseIcyMetaint({ 'Icy-MetaData': '1', 'ICY-METAINT': '8192' }), 8192);
  assert.equal(parseIcyMetaint({ 'content-type': 'audio/mpeg' }), 0);
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

test('recognizes old MP3 links that may carry Icecast metadata', () => {
  assert.equal(isProgressiveMp3Url('http://lhttp.qingting.fm/live/4915/64k.mp3'), true);
  assert.equal(isProgressiveMp3Url('https://radio.example/live.MP3?token=1'), true);
  assert.equal(isProgressiveMp3Url('https://radio.example/live.m3u8'), false);
});
