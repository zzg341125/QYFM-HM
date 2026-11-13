import assert from 'node:assert/strict';
import test from 'node:test';
import {
  isSearchStationAdded,
  shouldShowSearchResults
} from '../entry/src/main/ets/utils/SearchModel.ts';

test('hides old search results after the search box is cleared', () => {
  assert.equal(shouldShowSearchResults('', 5), false);
  assert.equal(shouldShowSearchResults('   ', 5), false);
});

test('shows results only for a non-empty query with matches', () => {
  assert.equal(shouldShowSearchResults('新闻', 0), false);
  assert.equal(shouldShowSearchResults('新闻', 2), true);
});

test('detects an added station by id or stream URL', () => {
  const stations = [
    { id: 'saved-1', streamUrl: 'https://example.com/a.m3u8' }
  ];

  assert.equal(isSearchStationAdded(stations, {
    id: 'saved-1',
    streamUrl: 'https://example.com/b.m3u8'
  }), true);
  assert.equal(isSearchStationAdded(stations, {
    id: 'new-1',
    streamUrl: 'https://example.com/a.m3u8'
  }), true);
  assert.equal(isSearchStationAdded(stations, {
    id: 'new-1',
    streamUrl: 'https://example.com/c.m3u8'
  }), false);
});
