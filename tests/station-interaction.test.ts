import assert from 'node:assert/strict';
import test from 'node:test';
import {
  stationRowTapAction,
  stationSwipeActions
} from '../entry/src/main/ets/utils/StationInteraction.ts';

test('station row taps always play and never open the editor', () => {
  assert.equal(stationRowTapAction(true), 'play');
  assert.equal(stationRowTapAction(false), 'play');
});

test('left swipe exposes edit and delete only when editing is enabled', () => {
  assert.deepEqual(stationSwipeActions(true), ['edit', 'delete']);
  assert.deepEqual(stationSwipeActions(false), []);
});
