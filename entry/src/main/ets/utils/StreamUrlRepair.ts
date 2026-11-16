export function migrateLegacyStreamUrl(url: string): string {
  const trimmed = url.trim();
  if (/^https?:\/\/live\.cztv\.cc:85\/live\/xwgb\.m3u8(?:[/?#].*)?$/i.test(trimmed)) {
    return 'https://live.ximalaya.com/radio-first-page-app/live/154/64.m3u8';
  }
  if (/^https:\/\/lhttp(?:-hw)?\.qtfm\.cn\//i.test(trimmed) ||
    /^https:\/\/lhttp\.qingting\.fm\//i.test(trimmed)) {
    return trimmed.replace(/^https:\/\//i, 'http://');
  }
  if (/^https?:\/\/radio\.936\.nz:8443\//i.test(trimmed)) {
    return trimmed.replace(
      /^https?:\/\/radio\.936\.nz:8443\//i,
      'http://radiolive.nz936.com:8443/'
    );
  }
  const legacyNer = trimmed.match(
    /^https?:\/\/cast\.ner\.gov\.tw\/(\d+)(?:[/?#].*)?$/i
  );
  if (legacyNer !== null) {
    return `https://wowza1.ner.gov.tw/TPFM/${legacyNer[1]}/playlist.m3u8`;
  }
  const nerHls = trimmed.match(
    /^https?:\/\/wowza1\.ner\.gov\.tw\/TPFM\/(\d+)\/(?:playlist|chunklist(?:_[^/?#]+)?)\.m3u8(?:[/?#].*)?$/i
  );
  if (nerHls !== null) {
    return `https://wowza1.ner.gov.tw/TPFM/${nerHls[1]}/playlist.m3u8`;
  }
  const taiwanHls = trimmed.match(
    /^https?:\/\/(stream\.ginnet\.cloud|flv\.ccdntech\.com|streamak0138\.akamaized\.net)(\/.*\/)(?:playlist|chunklist(?:_[^/?#]+)?)\.m3u8(?:[/?#].*)?$/i
  );
  if (taiwanHls !== null) {
    const playlistName = taiwanHls[1].toLowerCase() === 'stream.ginnet.cloud'
      ? 'playlist.m3u8'
      : 'chunklist.m3u8';
    return `http://${taiwanHls[1]}${taiwanHls[2]}${playlistName}`;
  }
  const revma = trimmed.match(
    /^https?:\/\/(?:n\d+[a-z]?-(?:eu|us)[a-z0-9]*|n13)\.rcs\.revma\.com\/([^/?#]+)(?:[/?#].*)?$/i
  );
  if (revma !== null) {
    return `http://n13.rcs.revma.com/${revma[1]}`;
  }
  if (/^https?:\/\/video1\.getstreamhosting\.com:8292\/stream\?\.mp3(?:&.*)?$/i
    .test(trimmed)) {
    return trimmed.replace(
      /^https:\/\//i,
      'http://'
    );
  }
  return trimmed;
}
