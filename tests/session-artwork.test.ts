import assert from 'node:assert/strict';
import test from 'node:test';
import { safeSessionArtwork } from '../entry/src/main/ets/utils/SessionArtwork.ts';

test('omits oversized Base64 artwork that AVSession rejects as metadata', () => {
  const oversized = `data:image/jpeg;base64,${'A'.repeat(76399)}`;
  assert.equal(safeSessionArtwork(oversized), '');
});

test('keeps valid remote artwork and rejects metadata longer than the system limit', () => {
  assert.equal(
    safeSessionArtwork('https://icons.example/radio.png'),
    'https://icons.example/radio.png'
  );
  assert.equal(safeSessionArtwork(`https://icons.example/${'a'.repeat(41000)}`), '');
  assert.equal(safeSessionArtwork(''), '');
});
