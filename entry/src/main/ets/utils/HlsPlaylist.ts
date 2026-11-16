export interface HlsMediaPlaylist {
  segments: string[];
  targetDurationSeconds: number;
}

export function hlsInitialSegmentCount(targetDurationSeconds: number): number {
  return targetDurationSeconds > 0 && targetDurationSeconds <= 3 ? 2 : 1;
}

export type HlsSegmentData = ArrayBuffer | Uint8Array;

export function hasUsableHlsSegments(
  chunks: Array<HlsSegmentData | undefined>
): boolean {
  return chunks.some((chunk: HlsSegmentData | undefined): boolean => {
    return chunk !== undefined && chunk.byteLength > 0;
  });
}

export function detectHlsSegmentCodec(data: Uint8Array): 'aac' | 'mp3' | undefined {
  const audio = stripLeadingId3(data);
  if (audio.length < 2 || audio[0] !== 0xff || (audio[1] & 0xe0) !== 0xe0) {
    return undefined;
  }
  return ((audio[1] >> 1) & 0x03) === 0 ? 'aac' : 'mp3';
}

export type HlsRequestKind = 'playlist' | 'segment';

export function hlsRequestReferer(
  kind: HlsRequestKind,
  masterUrl: string,
  mediaUrl: string
): string {
  return kind === 'playlist' ? masterUrl.trim() : mediaUrl.trim();
}

export function isHlsPlaylistUrl(url: string): boolean {
  const path = url.trim().toLowerCase().split(/[?#]/)[0];
  return path.endsWith('.m3u8') || path.endsWith('/hls');
}

export function shouldUseManagedHlsReader(url: string): boolean {
  const trimmed = url.trim();
  return /^https?:\/\/wowza1\.ner\.gov\.tw\/TPFM\/\d+\//i.test(trimmed) ||
    /^https?:\/\/live\.(?:xmcdn|ximalaya)\.com(?::\d+)?\//i.test(trimmed) ||
    /^https?:\/\/stream\.ginnet\.cloud\//i.test(trimmed) ||
    /^https?:\/\/flv\.ccdntech\.com\//i.test(trimmed) ||
    /^https?:\/\/streamak0138\.akamaized\.net\//i.test(trimmed) ||
    isHlsPlaylistUrl(trimmed);
}

function normalizePath(path: string): string {
  const absolute = path.startsWith('/');
  const parts = path.split('/');
  const normalized: string[] = [];
  parts.forEach((part: string): void => {
    if (part.length === 0 || part === '.') {
      return;
    }
    if (part === '..') {
      if (normalized.length > 0) {
        normalized.pop();
      }
      return;
    }
    normalized.push(part);
  });
  return `${absolute ? '/' : ''}${normalized.join('/')}`;
}

export function resolveHlsUrl(baseUrl: string, reference: string): string {
  const base = baseUrl.trim();
  const value = reference.trim();
  if (/^https?:\/\//i.test(value)) {
    return value;
  }
  if (value.startsWith('//')) {
    const scheme = base.match(/^(https?):/i);
    return `${scheme === null ? 'https' : scheme[1].toLowerCase()}:${value}`;
  }
  const originMatch = base.match(/^(https?:\/\/[^/]+)/i);
  if (originMatch === null) {
    return value;
  }
  const origin = originMatch[1];
  const queryIndex = value.search(/[?#]/);
  const pathPart = queryIndex < 0 ? value : value.substring(0, queryIndex);
  const suffix = queryIndex < 0 ? '' : value.substring(queryIndex);
  if (pathPart.startsWith('/')) {
    return `${origin}${normalizePath(pathPart)}${suffix}`;
  }
  const basePath = base.split(/[?#]/)[0];
  const directoryEnd = basePath.lastIndexOf('/');
  const directory = directoryEnd < origin.length ? `${origin}/` : basePath.substring(0, directoryEnd + 1);
  return `${origin}${normalizePath(`${directory.substring(origin.length)}${pathPart}`)}${suffix}`;
}

function playlistLines(text: string): string[] {
  return text.split(/\r?\n/).map((line: string): string => line.trim());
}

export function parseHlsVariantUrl(text: string, baseUrl: string): string | undefined {
  const lines = playlistLines(text);
  for (let index = 0; index < lines.length; index++) {
    if (!lines[index].startsWith('#EXT-X-STREAM-INF')) {
      continue;
    }
    for (let next = index + 1; next < lines.length; next++) {
      const line = lines[next];
      if (line.length === 0 || line.startsWith('#')) {
        continue;
      }
      return resolveHlsUrl(baseUrl, line);
    }
  }
  return undefined;
}

export function parseHlsMediaPlaylist(text: string, baseUrl: string): HlsMediaPlaylist {
  const lines = playlistLines(text);
  let targetDurationSeconds = 2;
  const segments: string[] = [];
  lines.forEach((line: string): void => {
    if (line.startsWith('#EXT-X-TARGETDURATION:')) {
      const parsed = Number(line.substring('#EXT-X-TARGETDURATION:'.length));
      if (Number.isFinite(parsed) && parsed > 0) {
        targetDurationSeconds = parsed;
      }
      return;
    }
    if (line.length === 0 || line.startsWith('#')) {
      return;
    }
    const resolved = resolveHlsUrl(baseUrl, line);
    if (!segments.includes(resolved)) {
      segments.push(resolved);
    }
  });
  return {
    segments: segments,
    targetDurationSeconds: targetDurationSeconds
  };
}

export function stripLeadingId3(data: Uint8Array): Uint8Array {
  if (data.length < 10 || data[0] !== 0x49 || data[1] !== 0x44 || data[2] !== 0x33) {
    return data;
  }
  const size = ((data[6] & 0x7f) << 21) |
    ((data[7] & 0x7f) << 14) |
    ((data[8] & 0x7f) << 7) |
    (data[9] & 0x7f);
  const footerSize = (data[5] & 0x10) === 0 ? 0 : 10;
  const audioOffset = 10 + size + footerSize;
  return audioOffset < data.length ? data.slice(audioOffset) : new Uint8Array(0);
}
