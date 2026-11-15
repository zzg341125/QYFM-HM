export interface AndroidBackupLogoEntry {
  name: string;
  mimeType: string;
  base64: string;
}

export interface AndroidBackupSettingsPatch {
  dynamicColor?: boolean;
  transparentUi?: boolean;
  clickStationToPlay?: boolean;
  editMode?: boolean;
  editStreamUrl?: boolean;
  autoPlayOnLaunch?: boolean;
  playbackMemory?: boolean;
  fastStart?: boolean;
  largeBuffer?: boolean;
  pauseOnUnplug?: boolean;
  autoUpdate?: boolean;
  webdavUrl?: string;
  webdavUser?: string;
  webdavFile?: string;
}

export interface AndroidBackupStation {
  id: string;
  name: string;
  streamUrl: string;
  streamLines: AndroidBackupStreamLine[];
  activeLineIndex: number;
  iconUrl: string;
  tags: string;
  country: string;
  state: string;
  favorite: boolean;
}

export interface AndroidV108BackupResult {
  stations: AndroidBackupStation[];
  stationOrder: string[];
  settings: AndroidBackupSettingsPatch;
}

export interface AndroidBackupStreamLine {
  id: string;
  name: string;
  url: string;
  priority: number;
  isStable: boolean;
}

interface AndroidLineJson {
  lineId?: string;
  name?: string;
  url?: string;
  priority?: number;
  isStable?: boolean;
}

interface AndroidStationJson {
  stationuuid?: string;
  name?: string;
  url?: string;
  url_resolved?: string;
  favicon?: string;
  country?: string;
  state?: string;
  tags?: string;
  isFavorite?: boolean;
  lines?: AndroidLineJson[];
  activeLineIndex?: number;
}

interface AndroidManifestJson {
  stationOrder?: string[];
}

interface AndroidSettingsJson {
  pref_dynamic_color?: boolean;
  pref_transparent_ui?: boolean;
  pref_click_station_play?: boolean;
  pref_edit_station?: boolean;
  pref_edit_stream_url?: boolean;
  pref_auto_play_on_launch?: boolean;
  pref_playback_memory?: boolean;
  pref_fast_start?: boolean;
  pref_large_buffer?: boolean;
  pref_pause_on_unplug?: boolean;
  pref_auto_update_enabled?: boolean;
  pref_webdav_url?: string;
  pref_webdav_user?: string;
  pref_webdav_file?: string;
}

interface M3uResult {
  name: string;
  streamUrl: string;
  iconUrl: string;
}

function text(value: string | undefined): string {
  return typeof value === 'string' ? value.trim() : '';
}

function logoMap(logos: AndroidBackupLogoEntry[]): Map<string, AndroidBackupLogoEntry> {
  const result = new Map<string, AndroidBackupLogoEntry>();
  logos.forEach((logo: AndroidBackupLogoEntry) => {
    if (logo.name.length > 0 && logo.base64.length > 0) {
      result.set(logo.name, logo);
    }
  });
  return result;
}

function resolveIcon(
  favicon: string,
  logos: Map<string, AndroidBackupLogoEntry>
): string {
  if (!favicon.startsWith('logo:')) {
    return favicon;
  }
  const name = favicon.substring('logo:'.length);
  const logo = logos.get(name);
  if (logo === undefined) {
    return '';
  }
  return `data:${logo.mimeType};base64,${logo.base64}`;
}

function activeStreamUrl(station: AndroidStationJson): string {
  const lines = Array.isArray(station.lines) ? station.lines : [];
  const activeIndex = typeof station.activeLineIndex === 'number' ? station.activeLineIndex : 0;
  const activeLine = lines.length > activeIndex ? lines[activeIndex] : undefined;
  const activeUrl = activeLine === undefined ? '' : text(activeLine.url);
  if (activeUrl.length > 0) {
    return activeUrl;
  }
  const resolved = text(station.url_resolved);
  return resolved.length > 0 ? resolved : text(station.url);
}

function androidStreamLines(station: AndroidStationJson): AndroidBackupStreamLine[] {
  const sourceLines = Array.isArray(station.lines) ? station.lines : [];
  const lines: AndroidBackupStreamLine[] = [];
  const seen = new Set<string>();
  sourceLines.forEach((line: AndroidLineJson, index: number) => {
    const url = text(line.url);
    if (url.length === 0 || seen.has(url)) {
      return;
    }
    seen.add(url);
    lines.push({
      id: text(line.lineId).length > 0 ? text(line.lineId) : `line-${index + 1}`,
      name: text(line.name).length > 0 ? text(line.name) : `线路 ${index + 1}`,
      url: url,
      priority: typeof line.priority === 'number' ? line.priority : index + 1,
      isStable: line.isStable !== false
    });
  });
  if (lines.length === 0) {
    const fallbackUrl = activeStreamUrl(station);
    if (fallbackUrl.length > 0) {
      lines.push({
        id: 'default',
        name: '公网主线',
        url: fallbackUrl,
        priority: 1,
        isStable: false
      });
    }
  }
  return lines;
}

function validActiveLineIndex(station: AndroidStationJson, lineCount: number): number {
  if (lineCount === 0) {
    return 0;
  }
  const index = typeof station.activeLineIndex === 'number' ? station.activeLineIndex : 0;
  return index >= 0 && index < lineCount ? index : 0;
}

function parseJsonStations(
  playlistText: string,
  logos: Map<string, AndroidBackupLogoEntry>
): AndroidBackupStation[] {
  if (playlistText.trim().length === 0) {
    return [];
  }
  let playlist: AndroidStationJson[];
  try {
    playlist = JSON.parse(playlistText) as AndroidStationJson[];
  } catch (error) {
    return [];
  }
  if (!Array.isArray(playlist)) {
    return [];
  }
  const stations: AndroidBackupStation[] = [];
  const seenIds = new Set<string>();
  playlist.forEach((item: AndroidStationJson, index: number) => {
    const name = text(item.name);
    const streamUrl = activeStreamUrl(item);
    let id = text(item.stationuuid);
    if (id.length === 0) {
      id = `android-v108-${index + 1}`;
    }
    if (name.length === 0 || streamUrl.length === 0 || seenIds.has(id)) {
      return;
    }
    seenIds.add(id);
    const streamLines = androidStreamLines(item);
    stations.push({
      id: id,
      name: name,
      streamUrl: streamUrl,
      streamLines: streamLines,
      activeLineIndex: validActiveLineIndex(item, streamLines.length),
      iconUrl: resolveIcon(text(item.favicon), logos),
      tags: text(item.tags),
      country: text(item.country),
      state: text(item.state),
      favorite: item.isFavorite === true
    });
  });
  return stations;
}

function parseM3u(
  content: string,
  logos: Map<string, AndroidBackupLogoEntry>
): M3uResult[] {
  const result: M3uResult[] = [];
  const seenUrls = new Set<string>();
  let pendingName = '';
  let pendingLogo = '';
  content.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n').forEach((raw: string) => {
    const line = raw.trim().replaceAll('\uFEFF', '');
    if (line.toUpperCase().startsWith('#EXTINF')) {
      const comma = line.lastIndexOf(',');
      pendingName = comma >= 0 ? line.substring(comma + 1).trim() : '';
      const logoMatch = line.match(/tvg-logo\s*=\s*"([^"]*)"/i);
      pendingLogo = logoMatch === null ? '' : resolveIcon(logoMatch[1].trim(), logos);
      return;
    }
    if (line.length === 0 || line.startsWith('#') ||
      (!line.toLowerCase().startsWith('http://') && !line.toLowerCase().startsWith('https://')) ||
      seenUrls.has(line)) {
      return;
    }
    seenUrls.add(line);
    let fallbackName = line.substring(line.lastIndexOf('/') + 1).split('?')[0];
    if (fallbackName.length === 0) {
      fallbackName = line;
    }
    result.push({
      name: pendingName.length > 0 ? pendingName : fallbackName,
      streamUrl: line,
      iconUrl: pendingLogo
    });
    pendingName = '';
    pendingLogo = '';
  });
  return result;
}

function parseM3uStations(
  playlistM3uText: string,
  logos: Map<string, AndroidBackupLogoEntry>
): AndroidBackupStation[] {
  return parseM3u(playlistM3uText, logos).map((entry: M3uResult, index: number) => {
    return {
      id: `android-m3u-${index + 1}`,
      name: entry.name,
      streamUrl: entry.streamUrl,
      streamLines: [{
        id: 'default',
        name: 'M3U 主线',
        url: entry.streamUrl,
        priority: 1,
        isStable: false
      }],
      activeLineIndex: 0,
      iconUrl: entry.iconUrl,
      tags: 'M3U恢复',
      country: '',
      state: '',
      favorite: false
    };
  });
}

function parseStationOrder(
  manifestText: string,
  stations: AndroidBackupStation[]
): string[] {
  let manifest: AndroidManifestJson | undefined = undefined;
  if (manifestText.trim().length > 0) {
    try {
      manifest = JSON.parse(manifestText) as AndroidManifestJson;
    } catch (error) {
      manifest = undefined;
    }
  }
  const sourceOrder = manifest !== undefined && Array.isArray(manifest.stationOrder)
    ? manifest.stationOrder
    : [];
  const available = new Set<string>();
  stations.forEach((station: AndroidBackupStation) => available.add(station.id));
  const ordered: string[] = [];
  const seen = new Set<string>();
  sourceOrder.forEach((id: string) => {
    if (available.has(id) && !seen.has(id)) {
      seen.add(id);
      ordered.push(id);
    }
  });
  stations.forEach((station: AndroidBackupStation) => {
    if (!seen.has(station.id)) {
      seen.add(station.id);
      ordered.push(station.id);
    }
  });
  return ordered;
}

function parseSettings(settingsText: string): AndroidBackupSettingsPatch {
  const settings: AndroidBackupSettingsPatch = {};
  if (settingsText.trim().length === 0) {
    return settings;
  }
  let raw: AndroidSettingsJson;
  try {
    raw = JSON.parse(settingsText) as AndroidSettingsJson;
  } catch (error) {
    return settings;
  }
  if (typeof raw.pref_dynamic_color === 'boolean') {
    settings.dynamicColor = raw.pref_dynamic_color;
  }
  if (typeof raw.pref_transparent_ui === 'boolean') {
    settings.transparentUi = raw.pref_transparent_ui;
  }
  if (typeof raw.pref_click_station_play === 'boolean') {
    settings.clickStationToPlay = raw.pref_click_station_play;
  }
  if (typeof raw.pref_edit_station === 'boolean') {
    settings.editMode = raw.pref_edit_station;
  }
  if (typeof raw.pref_edit_stream_url === 'boolean') {
    settings.editStreamUrl = raw.pref_edit_stream_url;
  }
  if (typeof raw.pref_auto_play_on_launch === 'boolean') {
    settings.autoPlayOnLaunch = raw.pref_auto_play_on_launch;
  }
  if (typeof raw.pref_playback_memory === 'boolean') {
    settings.playbackMemory = raw.pref_playback_memory;
  }
  if (typeof raw.pref_fast_start === 'boolean') {
    settings.fastStart = raw.pref_fast_start;
  }
  if (typeof raw.pref_large_buffer === 'boolean') {
    settings.largeBuffer = raw.pref_large_buffer;
  }
  if (typeof raw.pref_pause_on_unplug === 'boolean') {
    settings.pauseOnUnplug = raw.pref_pause_on_unplug;
  }
  if (typeof raw.pref_auto_update_enabled === 'boolean') {
    settings.autoUpdate = raw.pref_auto_update_enabled;
  }
  if (typeof raw.pref_webdav_url === 'string') {
    settings.webdavUrl = raw.pref_webdav_url;
  }
  if (typeof raw.pref_webdav_user === 'string') {
    settings.webdavUser = raw.pref_webdav_user;
  }
  if (typeof raw.pref_webdav_file === 'string') {
    settings.webdavFile = raw.pref_webdav_file;
  }
  return settings;
}

export function parseAndroidV108Backup(
  manifestText: string,
  playlistText: string,
  playlistM3uText: string,
  settingsText: string,
  logos: AndroidBackupLogoEntry[]
): AndroidV108BackupResult {
  const logoEntries = logoMap(logos);
  let stations = parseJsonStations(playlistText, logoEntries);
  if (stations.length === 0) {
    stations = parseM3uStations(playlistM3uText, logoEntries);
  }
  if (stations.length === 0) {
    throw new Error('备份中没有可恢复的播放列表');
  }
  return {
    stations: stations,
    stationOrder: parseStationOrder(manifestText, stations),
    settings: parseSettings(settingsText)
  };
}
