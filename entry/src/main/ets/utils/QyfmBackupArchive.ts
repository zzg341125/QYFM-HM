import type { AndroidBackupLogoEntry } from './AndroidBackupModel';
import { orderStationsByBackup } from './BackupModel.ts';

interface ArchiveStreamLine {
  id: string;
  name: string;
  url: string;
  priority: number;
  isStable: boolean;
}

interface ArchiveStation {
  id: string;
  name: string;
  streamUrl: string;
  streamLines?: ArchiveStreamLine[];
  activeLineIndex?: number;
  iconUrl: string;
  tags: string;
  country: string;
  state: string;
  favorite: boolean;
}

interface ArchiveSettings {
  autoUpdate: boolean;
  autoResume: boolean;
  resumeWindowMinutes: number;
  editMode: boolean;
  editStreamUrl: boolean;
  themeId: string;
  dynamicColor: boolean;
  transparentUi: boolean;
  clickStationToPlay: boolean;
  autoPlayOnLaunch: boolean;
  playbackMemory: boolean;
  fastStart: boolean;
  largeBuffer: boolean;
  pauseOnUnplug: boolean;
  pauseOnBluetoothDisconnect: boolean;
  autoPlayOnBluetoothConnect: boolean;
  icecastCompatibility: boolean;
  ffmpegDecoder: boolean;
  lastStationId: string;
  webdavUrl: string;
  webdavUser: string;
  webdavPassword: string;
  webdavFile: string;
  bluetoothBindings: ArchiveBluetoothBinding[];
}

interface ArchiveBluetoothBinding {
  deviceId: string;
  deviceName: string;
  autoPlay: boolean;
  lastConnectedAt: number;
}

export interface QyfmArchiveResult {
  stations: ArchiveStation[];
  settings: ArchiveSettings;
}

export function isQyfmBackupPlaylist(text: string): boolean {
  return text.includes('#EXTM3U') && text.includes('#EXT-QYFM-FORMAT:1');
}

function encodeValue(value: string): string {
  return encodeURIComponent(value);
}

function decodeValue(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch (error) {
    return value;
  }
}

function decodeLogoBase64(logo: AndroidBackupLogoEntry | undefined): string {
  if (logo === undefined || logo.base64.length === 0 || logo.mimeType.length === 0) {
    return '';
  }
  return `data:${logo.mimeType};base64,${logo.base64}`;
}

function logoLookupName(path: string): string {
  const normalized = path.trim().replaceAll('\\', '/');
  const slash = normalized.lastIndexOf('/');
  return slash >= 0 ? normalized.substring(slash + 1) : normalized;
}

function defaultArchiveSettings(): ArchiveSettings {
  return {
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
    webdavFile: 'qyfm-backup.zip',
    bluetoothBindings: []
  };
}

export function serializeQyfmBackupPlaylist(
  stations: ArchiveStation[],
  logoFiles: Map<string, string>
): string {
  const lines: string[] = ['#EXTM3U', '#EXT-QYFM-FORMAT:1'];
  stations.forEach((station: ArchiveStation) => {
    const activeIndex = station.activeLineIndex ?? 0;
    const logo = logoFiles.get(station.id) ?? station.iconUrl;
    lines.push(`#EXT-QYFM-ID:${encodeValue(station.id)}`);
    lines.push(
      `#EXT-QYFM-META:${encodeValue(station.tags)}|${encodeValue(station.country)}|` +
      `${encodeValue(station.state)}|${station.favorite ? '1' : '0'}|${activeIndex}`
    );
    const streamLines = station.streamLines ?? [];
    streamLines.forEach((line: ArchiveStreamLine, index: number) => {
      lines.push(
        `#EXT-QYFM-LINE:${index}|${line.priority}|${line.isStable ? '1' : '0'}|` +
        `${encodeValue(line.id)}|${encodeValue(line.name)}|${encodeValue(line.url)}`
      );
    });
    const safeLogo = logo.replaceAll('"', '%22');
    const logoAttribute = safeLogo.length > 0 ? ` tvg-logo="${safeLogo}"` : '';
    lines.push(`#EXTINF:-1${logoAttribute},${station.name}`);
    lines.push(station.streamUrl);
  });
  return `${lines.join('\n')}\n`;
}

export function serializeQyfmBackupSettings(settings: ArchiveSettings): string {
  const fields: Array<[string, string]> = [
    ['autoUpdate', settings.autoUpdate ? '1' : '0'],
    ['autoResume', settings.autoResume ? '1' : '0'],
    ['resumeWindowMinutes', settings.resumeWindowMinutes.toString()],
    ['editMode', settings.editMode ? '1' : '0'],
    ['editStreamUrl', settings.editStreamUrl ? '1' : '0'],
    ['themeId', encodeValue(settings.themeId)],
    ['dynamicColor', settings.dynamicColor ? '1' : '0'],
    ['transparentUi', settings.transparentUi ? '1' : '0'],
    ['clickStationToPlay', settings.clickStationToPlay ? '1' : '0'],
    ['autoPlayOnLaunch', settings.autoPlayOnLaunch ? '1' : '0'],
    ['playbackMemory', settings.playbackMemory ? '1' : '0'],
    ['fastStart', settings.fastStart ? '1' : '0'],
    ['largeBuffer', settings.largeBuffer ? '1' : '0'],
    ['pauseOnUnplug', settings.pauseOnUnplug ? '1' : '0'],
    ['pauseOnBluetoothDisconnect', settings.pauseOnBluetoothDisconnect ? '1' : '0'],
    ['autoPlayOnBluetoothConnect', settings.autoPlayOnBluetoothConnect ? '1' : '0'],
    ['icecastCompatibility', settings.icecastCompatibility ? '1' : '0'],
    ['ffmpegDecoder', settings.ffmpegDecoder ? '1' : '0'],
    ['lastStationId', encodeValue(settings.lastStationId)],
    ['webdavUrl', encodeValue(settings.webdavUrl)],
    ['webdavUser', encodeValue(settings.webdavUser)],
    ['webdavFile', encodeValue(settings.webdavFile)]
  ];
  fields.push(['bluetoothBindingCount', settings.bluetoothBindings.length.toString()]);
  settings.bluetoothBindings.slice(0, 3).forEach((binding: ArchiveBluetoothBinding, index: number) => {
    fields.push([`bluetoothBinding.${index}.deviceId`, encodeValue(binding.deviceId)]);
    fields.push([`bluetoothBinding.${index}.deviceName`, encodeValue(binding.deviceName)]);
    fields.push([`bluetoothBinding.${index}.autoPlay`, binding.autoPlay ? '1' : '0']);
    fields.push([
      `bluetoothBinding.${index}.lastConnectedAt`,
      binding.lastConnectedAt.toString()
    ]);
  });
  return `${fields.map((field: [string, string]): string => `${field[0]}=${field[1]}`).join('\n')}\n`;
}

function parseSettings(text: string): ArchiveSettings {
  const settings = defaultArchiveSettings();
  const values = new Map<string, string>();
  text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n').forEach((line: string) => {
    const separator = line.indexOf('=');
    if (separator > 0) {
      values.set(line.substring(0, separator), line.substring(separator + 1));
    }
  });
  const booleanValue = (key: string, fallback: boolean): boolean => {
    const value = values.get(key);
    return value === undefined ? fallback : value === '1';
  };
  settings.autoUpdate = booleanValue('autoUpdate', settings.autoUpdate);
  settings.autoResume = booleanValue('autoResume', settings.autoResume);
  const resumeWindow = Number(values.get('resumeWindowMinutes'));
  if (Number.isFinite(resumeWindow)) {
    settings.resumeWindowMinutes = resumeWindow;
  }
  settings.editMode = booleanValue('editMode', settings.editMode);
  settings.editStreamUrl = booleanValue('editStreamUrl', settings.editStreamUrl);
  settings.themeId = decodeValue(values.get('themeId') ?? settings.themeId);
  settings.dynamicColor = booleanValue('dynamicColor', settings.dynamicColor);
  settings.transparentUi = booleanValue('transparentUi', settings.transparentUi);
  settings.clickStationToPlay = booleanValue('clickStationToPlay', settings.clickStationToPlay);
  settings.autoPlayOnLaunch = booleanValue('autoPlayOnLaunch', settings.autoPlayOnLaunch);
  settings.playbackMemory = booleanValue('playbackMemory', settings.playbackMemory);
  settings.fastStart = booleanValue('fastStart', settings.fastStart);
  settings.largeBuffer = booleanValue('largeBuffer', settings.largeBuffer);
  settings.pauseOnUnplug = booleanValue('pauseOnUnplug', settings.pauseOnUnplug);
  settings.pauseOnBluetoothDisconnect = booleanValue(
    'pauseOnBluetoothDisconnect',
    settings.pauseOnBluetoothDisconnect
  );
  settings.autoPlayOnBluetoothConnect = booleanValue(
    'autoPlayOnBluetoothConnect',
    settings.autoPlayOnBluetoothConnect
  );
  settings.icecastCompatibility = booleanValue(
    'icecastCompatibility',
    settings.icecastCompatibility
  );
  settings.ffmpegDecoder = booleanValue('ffmpegDecoder', settings.ffmpegDecoder);
  settings.lastStationId = decodeValue(values.get('lastStationId') ?? settings.lastStationId);
  settings.webdavUrl = decodeValue(values.get('webdavUrl') ?? settings.webdavUrl);
  settings.webdavUser = decodeValue(values.get('webdavUser') ?? settings.webdavUser);
  settings.webdavFile = decodeValue(values.get('webdavFile') ?? settings.webdavFile);
  const bindingCount = Math.min(3, Math.max(0, Number(values.get('bluetoothBindingCount')) || 0));
  for (let index = 0; index < bindingCount; index++) {
    const deviceId = decodeValue(values.get(`bluetoothBinding.${index}.deviceId`) ?? '');
    const lastConnectedAt = Number(values.get(`bluetoothBinding.${index}.lastConnectedAt`));
    if (deviceId.length > 0) {
      settings.bluetoothBindings.push({
        deviceId: deviceId,
        deviceName: decodeValue(values.get(`bluetoothBinding.${index}.deviceName`) ?? ''),
        autoPlay: values.get(`bluetoothBinding.${index}.autoPlay`) === '1',
        lastConnectedAt: Number.isFinite(lastConnectedAt) ? lastConnectedAt : 0
      });
    }
  }
  return settings;
}

export function parseQyfmBackupArchive(
  playlistText: string,
  orderText: string,
  settingsText: string,
  logos: AndroidBackupLogoEntry[]
): QyfmArchiveResult {
  if (!isQyfmBackupPlaylist(playlistText)) {
    throw new Error('QYFM ZIP 中缺少 M3U 播放列表');
  }
  const logoMap = new Map<string, AndroidBackupLogoEntry>();
  logos.forEach((logo: AndroidBackupLogoEntry) => logoMap.set(logo.name, logo));
  const stations: ArchiveStation[] = [];
  let id = '';
  let tags = '';
  let country = '';
  let state = '';
  let favorite = false;
  let activeLineIndex = 0;
  let lines: ArchiveStreamLine[] = [];
  let pendingName = '';
  let pendingLogo = '';
  playlistText.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n').forEach((raw: string) => {
    const line = raw.trim();
    if (line.startsWith('#EXT-QYFM-ID:')) {
      id = decodeValue(line.substring('#EXT-QYFM-ID:'.length));
      return;
    }
    if (line.startsWith('#EXT-QYFM-META:')) {
      const fields = line.substring('#EXT-QYFM-META:'.length).split('|');
      tags = decodeValue(fields[0] ?? '');
      country = decodeValue(fields[1] ?? '');
      state = decodeValue(fields[2] ?? '');
      favorite = fields[3] === '1';
      const parsedIndex = Number(fields[4]);
      activeLineIndex = Number.isFinite(parsedIndex) ? parsedIndex : 0;
      return;
    }
    if (line.startsWith('#EXT-QYFM-LINE:')) {
      const fields = line.substring('#EXT-QYFM-LINE:'.length).split('|');
      const parsedIndex = Number(fields[0]);
      const priority = Number(fields[1]);
      const url = decodeValue(fields[5] ?? '');
      if (url.length > 0 && Number.isFinite(parsedIndex)) {
        lines.push({
          id: decodeValue(fields[3] ?? `line-${parsedIndex + 1}`),
          name: decodeValue(fields[4] ?? `线路 ${parsedIndex + 1}`),
          url: url,
          priority: Number.isFinite(priority) ? priority : parsedIndex + 1,
          isStable: fields[2] === '1'
        });
      }
      return;
    }
    if (line.startsWith('#EXTINF')) {
      const comma = line.lastIndexOf(',');
      pendingName = comma >= 0 ? line.substring(comma + 1).trim() : '';
      const logoMatch = line.match(/tvg-logo\s*=\s*"([^"]*)"/i);
      pendingLogo = logoMatch === null ? '' : decodeValue(logoMatch[1].trim());
      return;
    }
    if (line.length === 0 || line.startsWith('#')) {
      return;
    }
    if (!line.toLowerCase().startsWith('http://') && !line.toLowerCase().startsWith('https://')) {
      return;
    }
    const stationId = id.length > 0 ? id : `qyfm-zip-${stations.length + 1}`;
    const streamLines = lines.length > 0 ? lines : [{
      id: 'default',
      name: 'M3U 主线',
      url: line,
      priority: 1,
      isStable: false
    }];
    const safeActiveIndex = activeLineIndex >= 0 && activeLineIndex < streamLines.length
      ? activeLineIndex
      : 0;
    const localLogo = pendingLogo.startsWith('logos/')
      ? decodeLogoBase64(logoMap.get(logoLookupName(pendingLogo)))
      : pendingLogo;
    stations.push({
      id: stationId,
      name: pendingName.length > 0 ? pendingName : stationId,
      streamUrl: line,
      streamLines: streamLines,
      activeLineIndex: safeActiveIndex,
      iconUrl: localLogo,
      tags: tags,
      country: country,
      state: state,
      favorite: favorite
    });
    id = '';
    tags = '';
    country = '';
    state = '';
    favorite = false;
    activeLineIndex = 0;
    lines = [];
    pendingLogo = '';
  });
  if (stations.length === 0) {
    throw new Error('QYFM M3U 播放列表中没有可恢复的电台');
  }
  const order = orderText.replaceAll('\r\n', '\n').replaceAll('\r', '\n')
    .split('\n')
    .map((entry: string): string => entry.trim())
    .filter((entry: string): boolean => entry.length > 0);
  return {
    stations: orderStationsByBackup(stations, order),
    settings: parseSettings(settingsText)
  };
}
