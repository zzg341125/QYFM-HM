import assert from 'node:assert/strict';
import test from 'node:test';
import {
  parseAndroidV108Backup
} from '../entry/src/main/ets/utils/AndroidBackupModel.ts';

test('restores Android v1.0.8 playlist data, logo references, order and settings', () => {
  const result = parseAndroidV108Backup(
    JSON.stringify({ stationOrder: ['b', 'a'] }),
    JSON.stringify([
      {
        stationuuid: 'a',
        name: '新闻台',
        url: 'http://old.example/a',
        urlResolved: 'http://resolved.example/a',
        favicon: 'logo:a.png',
        country: '中国',
        state: '河北',
        tags: '新闻',
        isFavorite: true,
        lines: [{ url: 'https://active.example/a.m3u8' }],
        activeLineIndex: 0
      },
      {
        stationuuid: 'b',
        name: '音乐台',
        url: 'https://music.example/b',
        favicon: 'https://icons.example/b.png'
      }
    ]),
    '',
    JSON.stringify({
      pref_dynamic_color: false,
      pref_transparent_ui: true,
      pref_webdav_url: 'https://dav.example/radio/'
    }),
    [{ name: 'a.png', mimeType: 'image/png', base64: 'QUJD' }]
  );

  assert.deepEqual(result.stationOrder, ['b', 'a']);
  assert.equal(result.stations.length, 2);
  const news = result.stations.find((station) => station.id === 'a');
  assert.equal(news?.streamUrl, 'https://active.example/a.m3u8');
  assert.equal(news?.iconUrl, 'data:image/png;base64,QUJD');
  assert.equal(news?.favorite, true);
  assert.equal(result.settings.dynamicColor, false);
  assert.equal(result.settings.transparentUi, true);
  assert.equal(result.settings.webdavUrl, 'https://dav.example/radio/');
});

test('falls back to playlist.m3u when playlist.json is absent', () => {
  const result = parseAndroidV108Backup(
    '',
    '',
    '#EXTM3U\n#EXTINF:-1 tvg-logo="https://icons.example/news.png",新闻\nhttps://stream.example/news.m3u8\n',
    '',
    []
  );

  assert.equal(result.stations.length, 1);
  assert.equal(result.stations[0].name, '新闻');
  assert.equal(result.stations[0].streamUrl, 'https://stream.example/news.m3u8');
  assert.equal(result.stations[0].iconUrl, 'https://icons.example/news.png');
  assert.deepEqual(result.stationOrder, [result.stations[0].id]);
});

test('rejects a ZIP backup without a playlist or M3U', () => {
  assert.throws(
    () => parseAndroidV108Backup('', '', '', '', []),
    /播放列表/
  );
});
