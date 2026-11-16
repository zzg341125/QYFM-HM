import assert from 'node:assert/strict';
import test from 'node:test';
import {
  buildOfficialStreamUrls,
  inferRadioCnProvinceCode,
  matchRadioCnStation,
  mergeOfficialStreamUrls,
  radioCnRequestTimeouts,
  shouldReuseRadioCnCatalog,
  shouldResolveRadioCnStation
} from '../entry/src/main/ets/utils/RadioCnMatch.ts';

test('infers the official radio.cn province for regional station names', () => {
  assert.equal(inferRadioCnProvinceCode('滁州新闻综合频道'), 340000);
  assert.equal(inferRadioCnProvinceCode('安徽交通广播'), 340000);
  assert.equal(inferRadioCnProvinceCode('中国之声'), 0);
  assert.equal(inferRadioCnProvinceCode('新西兰994交通音乐台'), undefined);
});

test('matches old imported station names to current official radio.cn titles', () => {
  assert.equal(matchRadioCnStation('神州之声', ['神州之声', '音乐之声']), '神州之声');
  assert.equal(matchRadioCnStation('中央音乐之声', ['中国之声', '音乐之声']), '音乐之声');
  assert.equal(
    matchRadioCnStation('中央经典流行音乐', ['经典音乐广播', '文艺之声']),
    '经典音乐广播'
  );
  assert.equal(
    matchRadioCnStation('滁州新闻综合频道', ['滁州综合广播', '滁州旅游交通广播']),
    '滁州综合广播'
  );
  assert.equal(matchRadioCnStation('新西兰994交通音乐台', ['音乐之声']), undefined);
});

test('requests official refresh only for recognized national and regional stations', () => {
  assert.equal(shouldResolveRadioCnStation('神州之声'), true);
  assert.equal(shouldResolveRadioCnStation('中央音乐之声'), true);
  assert.equal(shouldResolveRadioCnStation('中央经典流行音乐'), true);
  assert.equal(shouldResolveRadioCnStation('滁州旅游交通广播'), true);
  assert.equal(shouldResolveRadioCnStation('新西兰994交通音乐台'), false);
});

test('keeps the official stream first and the imported public URL as fallback', () => {
  assert.deepEqual(
    mergeOfficialStreamUrls(
      'https://official.example/live.m3u8',
      'https://old.example/live.m3u8'
    ),
    ['https://official.example/live.m3u8', 'https://old.example/live.m3u8']
  );
  assert.deepEqual(
    mergeOfficialStreamUrls('https://same.example/live', 'https://same.example/live'),
    ['https://same.example/live']
  );
});

test('retains all official stream variants before the imported public URL', () => {
  assert.deepEqual(
    buildOfficialStreamUrls(
      'https://official.example/high.mp3',
      'https://official.example/low.mp3',
      'https://official.example/live.m3u8',
      'https://old.example/live.m3u8'
    ),
    [
      'https://official.example/high.mp3',
      'https://official.example/low.mp3',
      'https://official.example/live.m3u8',
      'https://old.example/live.m3u8'
    ]
  );
});

test('allows the official catalog enough time to return during busy live playback', () => {
  const timeouts = radioCnRequestTimeouts();
  assert.ok(timeouts.connectTimeoutMs >= 5000);
  assert.ok(timeouts.readTimeoutMs >= 8000);
});

test('does not reuse official catalog responses after their signed URLs age out', () => {
  assert.equal(shouldReuseRadioCnCatalog(1000, 30999), true);
  assert.equal(shouldReuseRadioCnCatalog(1000, 31000), false);
  assert.equal(shouldReuseRadioCnCatalog(31000, 1000), false);
});
