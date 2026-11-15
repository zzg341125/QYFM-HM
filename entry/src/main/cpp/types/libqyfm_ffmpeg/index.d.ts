export interface QyfmFfmpeg {
  createDecoder(codec: string): number;
  decode(handle: number, data: ArrayBuffer, flush?: boolean): ArrayBuffer;
  destroyDecoder(handle: number): void;
  lastError(handle: number): number;
  outputSampleRate(): number;
  outputChannels(): number;
}

declare const ffmpeg: QyfmFfmpeg;
export default ffmpeg;
