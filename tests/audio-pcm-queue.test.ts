import assert from 'node:assert/strict';
import test from 'node:test';
import {
  AudioPcmQueue,
  buildPcmWriteChunkSize
} from '../entry/src/main/ets/utils/AudioPcmQueue.ts';

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

test('keeps the newest PCM from a decode buffer larger than the whole budget', () => {
  const queue = new AudioPcmQueue(4);
  queue.enqueue(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]).buffer);

  assert.equal(queue.byteLength, 4);
  assert.deepEqual(
    Array.from(new Uint8Array(queue.dequeue() ?? new ArrayBuffer(0))),
    [5, 6, 7, 8]
  );
});

test('writes PCM in small continuous frames instead of one-second bursts', () => {
  assert.equal(buildPcmWriteChunkSize(48000, 2, 4, 20), 7680);
  assert.equal(buildPcmWriteChunkSize(44100, 1, 2, 20), 1764);
});
