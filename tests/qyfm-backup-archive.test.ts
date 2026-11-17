import assert from 'node:assert/strict';
import test from 'node:test';
import {
  isQyfmBackupPlaylist,
  parseQyfmBackupArchive,
  serializeQyfmBackupPlaylist,
  serializeQyfmBackupSettings
} from '../entry/src/main/ets/utils/QyfmBackupArchive.ts';
import type { AndroidBackupLogoEntry } from '../entry/src/main/ets/utils/AndroidBackupModel.ts';

const stations = [
  {
    id: 'news',
    name: '新闻台',
    streamUrl: 'https://stream.example/news.m3u8',
    streamLines: [
      {
        id: 'news-main',
        name: '官方线路',
        url: 'https://stream.example/news.m3u8',
        priority: 1,
        isStable: true
      },
      {
        id: 'news-backup',
        name: '备用线路',
        url: 'https://backup.example/news.mp3',
        priority: 2,
        isStable: false
      }
    ],
    activeLineIndex: 1,
    iconUrl: 'data:image/png;base64,QUJD',
    tags: '新闻,综合',
    country: '中国',
    state: '安徽',
    favorite: true
  },
  {
    id: 'music',
    name: '音乐台',
    streamUrl: 'https://stream.example/music.mp3',
    iconUrl: 'https://icons.example/music.png',
    tags: '音乐',
    country: '中国',
    state: '江苏',
    favorite: false
  }
];

const logos: AndroidBackupLogoEntry[] = [
  { name: 'news.png', mimeType: 'image/png', base64: 'QUJD' }
];

test('restores the specified QYFM ZIP order, lines, metadata and bundled icons', () => {
  const logoFiles = new Map<string, string>([
    ['news', 'logos/news.png'],
    ['music', 'https://icons.example/music.png']
  ]);
  const playlist = serializeQyfmBackupPlaylist(stations, logoFiles);
  const settings = {
    autoUpdate: true,
    autoResume: true,
    resumeWindowMinutes: 120,
    editMode: true,
    editStreamUrl: true,
    themeId: 'lunar_light',
    dynamicColor: true,
    transparentUi: false,
    clickStationToPlay: true,
    autoPlayOnLaunch: true,
    playbackMemory: true,
    fastStart: true,
    largeBuffer: false,
    pauseOnUnplug: true,
    pauseOnBluetoothDisconnect: true,
    autoPlayOnBluetoothConnect: true,
    icecastCompatibility: true,
    ffmpegDecoder: true,
    lastStationId: '',
    webdavUrl: '',
    webdavUser: '',
    webdavPassword: '',
    webdavFile: 'qyfm-backup.json',
    bluetoothBindings: [{
      deviceId: 'car-audio',
      deviceName: 'Car Audio',
      autoPlay: true,
      lastConnectedAt: 1000
    }, {
      deviceId: 'headphones',
      deviceName: 'Headphones',
      autoPlay: false,
      lastConnectedAt: 2000
    }]
  };
  settings.dynamicColor = false;
  settings.resumeWindowMinutes = 45;
  settings.webdavPassword = 'must-not-be-exported';

  const parsed = parseQyfmBackupArchive(
    playlist,
    'music\nnews\n',
    serializeQyfmBackupSettings(settings),
    logos
  );

  assert.deepEqual(parsed.stations.map((station) => station.id), ['music', 'news']);
  const news = parsed.stations.find((station) => station.id === 'news');
  assert.equal(news?.activeLineIndex, 1);
  assert.deepEqual(news?.streamLines?.map((line) => line.id), ['news-main', 'news-backup']);
  assert.equal(news?.iconUrl, 'data:image/png;base64,QUJD');
  assert.equal(news?.favorite, true);
  assert.equal(parsed.settings.dynamicColor, false);
  assert.equal(parsed.settings.resumeWindowMinutes, 45);
  assert.deepEqual(parsed.settings.bluetoothBindings, settings.bluetoothBindings);
  assert.equal(serializeQyfmBackupSettings(settings).includes('must-not-be-exported'), false);
});

test('rejects a QYFM ZIP without an M3U playlist', () => {
  assert.throws(
    () => parseQyfmBackupArchive('', '', '', []),
    /M3U/
  );
});

test('does not mistake an Android v1.0.8 M3U for the QYFM ZIP format', () => {
  assert.equal(
    isQyfmBackupPlaylist('#EXTM3U\n#EXTINF:-1,旧电台\nhttps://old.example/live\n'),
    false
  );
  assert.equal(isQyfmBackupPlaylist('#EXTM3U\n#EXT-QYFM-FORMAT:1\n'), true);
});

test('restores an empty Bluetooth binding list from older settings files', () => {
  const playlist = serializeQyfmBackupPlaylist(stations, new Map<string, string>());
  const parsed = parseQyfmBackupArchive(playlist, 'news\nmusic\n', '', []);
  assert.deepEqual(parsed.settings.bluetoothBindings, []);
});
