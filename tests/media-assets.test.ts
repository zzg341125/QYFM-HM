import assert from 'node:assert/strict';
import test from 'node:test';
import {
  detectImageMimeType
} from '../entry/src/main/ets/utils/MediaAssets.ts';

test('detects PNG artwork even when the content URI has no file suffix', () => {
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  assert.equal(detectImageMimeType(png, 'content://media/12345'), 'image/png');
});

test('detects JPEG and WebP artwork from file signatures', () => {
  const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0]);
  const webp = new Uint8Array([
    0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50
  ]);
  assert.equal(detectImageMimeType(jpeg, 'content://media/1'), 'image/jpeg');
  assert.equal(detectImageMimeType(webp, 'content://media/2'), 'image/webp');
});
