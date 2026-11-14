import assert from 'node:assert/strict';
import test from 'node:test';
import {
  moveListItem
} from '../entry/src/main/ets/utils/ListOrdering.ts';

test('moves a station down and up without changing other items relative order', () => {
  assert.deepEqual(
    moveListItem(['a', 'b', 'c', 'd'], 1, 3),
    ['a', 'c', 'd', 'b']
  );
  assert.deepEqual(
    moveListItem(['a', 'b', 'c', 'd'], 3, 1),
    ['a', 'd', 'b', 'c']
  );
});

test('ignores an invalid drag move', () => {
  assert.deepEqual(moveListItem(['a', 'b'], 0, 5), ['a', 'b']);
});
