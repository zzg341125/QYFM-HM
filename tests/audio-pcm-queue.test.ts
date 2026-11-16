import assert from 'node:assert/strict';
import test from 'node:test';
import { AudioPcmQueue } from '../entry/src/main/ets/utils/AudioPcmQueue.ts';

function pcm(value: number): ArrayBuffer {
  return new Uint8Array([value]).buffer;
}

test('drops stale PCM and keeps only the newest audio within the live budget', () => {
  const queue = new AudioPcmQueue(3);
  queue.enqueue(pcm(1));
  queue.enqueue(pcm(2));
  queue.enqueue(pcm(3));
  queue.enqueue(pcm(4));

  assert.equal(queue.byteLength, 3);
  assert.deepEqual(Array.from(new Uint8Array(queue.dequeue() ?? new ArrayBuffer(0))), [2]);
  assert.deepEqual(Array.from(new Uint8Array(queue.dequeue() ?? new ArrayBuffer(0))), [3]);
  assert.deepEqual(Array.from(new Uint8Array(queue.dequeue() ?? new ArrayBuffer(0))), [4]);
  assert.equal(queue.dequeue(), undefined);
});
