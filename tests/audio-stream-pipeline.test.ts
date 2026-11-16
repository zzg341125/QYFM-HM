import assert from 'node:assert/strict';
import test from 'node:test';
import { HttpAudioStreamDecoder } from '../entry/src/main/ets/utils/IcyMetadata.ts';

function bytes(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

test('dechunks HTTP audio before decoding even without ICY metadata', () => {
  const decoder = new HttpAudioStreamDecoder();
  decoder.configure(true, 0);

  const first = decoder.push(bytes('4\r\nAA'));
  const second = decoder.push(bytes('BB\r\n3\r\nCCC\r\n0\r\n\r\n'));

  assert.deepEqual(Array.from(first), []);
  assert.deepEqual(Array.from(second), Array.from(bytes('AABBCCC')));
  assert.equal(decoder.isEnded(), true);
});

test('removes ICY metadata after dechunking a live HTTP stream', () => {
  const audioAndMetadata = new Uint8Array(25);
  audioAndMetadata.set([1, 2, 3, 4, 1, 84], 0);
  audioAndMetadata.set(new Array<number>(15).fill(0), 6);
  audioAndMetadata.set([5, 6, 7, 8], 21);
  const wire = new Uint8Array([
    ...bytes('9\r\n'), ...audioAndMetadata.slice(0, 9), ...bytes('\r\n'),
    ...bytes('10\r\n'), ...audioAndMetadata.slice(9), ...bytes('\r\n'),
    ...bytes('0\r\n\r\n')
  ]);
  const decoder = new HttpAudioStreamDecoder();
  decoder.configure(true, 4);

  const first = decoder.push(wire.slice(0, 14));
  const second = decoder.push(wire.slice(14));

  assert.deepEqual(Array.from(first), [1, 2, 3, 4]);
  assert.deepEqual(Array.from(second), [5, 6, 7, 8]);
  assert.equal(decoder.isEnded(), true);
});
