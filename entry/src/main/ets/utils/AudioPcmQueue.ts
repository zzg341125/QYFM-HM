export class AudioPcmQueue {
  private items: ArrayBuffer[] = [];
  private bytes: number = 0;
  private readonly maxBytes: number;

  constructor(maxBytes: number) {
    this.maxBytes = Math.max(1, Math.floor(maxBytes));
  }

  get byteLength(): number {
    return this.bytes;
  }

  enqueue(pcm: ArrayBuffer): void {
    if (pcm.byteLength <= 0) {
      return;
    }
    if (pcm.byteLength > this.maxBytes) {
      const alignedMaxBytes = this.maxBytes - (this.maxBytes % 4);
      if (alignedMaxBytes <= 0) {
        return;
      }
      this.items = [pcm.slice(pcm.byteLength - alignedMaxBytes)];
      this.bytes = alignedMaxBytes;
      return;
    }
    while (this.items.length > 0 && this.bytes + pcm.byteLength > this.maxBytes) {
      const oldest = this.items.shift();
      if (oldest !== undefined) {
        this.bytes -= oldest.byteLength;
      }
    }
    this.items.push(pcm);
    this.bytes += pcm.byteLength;
  }

  dequeue(): ArrayBuffer | undefined {
    const pcm = this.items.shift();
    if (pcm !== undefined) {
      this.bytes -= pcm.byteLength;
    }
    return pcm;
  }

  clear(): void {
    this.items = [];
    this.bytes = 0;
  }
}

export function buildPcmWriteChunkSize(
  sampleRate: number,
  channels: number,
  bytesPerSample: number,
  durationMs: number
): number {
  const frameBytes = Math.max(1, channels * bytesPerSample);
  const requested = Math.floor(sampleRate * frameBytes * durationMs / 1000);
  return Math.max(frameBytes, requested - (requested % frameBytes));
}
