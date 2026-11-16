export type DecoderEngine = 'native' | 'ffmpeg';

export function selectPrimaryDecoderEngine(url: string): DecoderEngine {
  return /^https?:\/\/wowza1\.ner\.gov\.tw\/TPFM\/\d+\//i.test(url.trim()) ||
    /^https?:\/\/live\.(?:xmcdn|ximalaya)\.com\//i.test(url.trim())
    ? 'ffmpeg'
    : 'native';
}

export function canFallbackToFfmpeg(supported: boolean): boolean {
  return supported;
}

export function buildDecoderAttemptOrder(url: string, ffmpegSupported: boolean): DecoderEngine[] {
  const primary = selectPrimaryDecoderEngine(url);
  if (!canFallbackToFfmpeg(ffmpegSupported)) {
    return [primary];
  }
  return [primary, primary === 'native' ? 'ffmpeg' : 'native'];
}
