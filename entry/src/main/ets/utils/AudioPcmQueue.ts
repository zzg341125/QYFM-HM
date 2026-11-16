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
    if (pcm.byteLength <= 0 || pcm.byteLength > this.maxBytes) {
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
