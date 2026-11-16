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
