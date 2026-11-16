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

  dequeueCombined(maxBytes: number): ArrayBuffer | undefined {
    if (this.items.length === 0) {
      return undefined;
    }
    const limit = Math.max(1, Math.floor(maxBytes));
    const selected: ArrayBuffer[] = [];
    let total = 0;
    while (this.items.length > 0) {
      const next = this.items[0];
      if (selected.length > 0 && total + next.byteLength > limit) {
        break;
      }
      this.items.shift();
      selected.push(next);
      total += next.byteLength;
      this.bytes -= next.byteLength;
      if (total >= limit) {
        break;
      }
    }
    if (selected.length === 1) {
      return selected[0];
    }
    const combined = new Uint8Array(total);
    let offset = 0;
    selected.forEach((chunk: ArrayBuffer): void => {
      combined.set(new Uint8Array(chunk), offset);
      offset += chunk.byteLength;
    });
    return combined.buffer;
  }

  clear(): void {
    this.items = [];
    this.bytes = 0;
  }
}

export class AudioPcmQueueReader {
  private readonly queue: AudioPcmQueue;
  private current: Uint8Array | undefined = undefined;
  private offset: number = 0;

  constructor(queue: AudioPcmQueue) {
    this.queue = queue;
  }

  readInto(destination: Uint8Array): number {
    let written = 0;
    while (written < destination.length) {
      if (this.current === undefined || this.offset >= this.current.length) {
        const next = this.queue.dequeue();
        if (next === undefined) {
          break;
        }
        this.current = new Uint8Array(next);
        this.offset = 0;
      }
      const count = Math.min(
        destination.length - written,
        this.current.length - this.offset
      );
      destination.set(this.current.subarray(this.offset, this.offset + count), written);
      this.offset += count;
      written += count;
    }
    if (written < destination.length) {
      destination.fill(0, written);
    }
    return written;
  }

  reset(): void {
    this.current = undefined;
    this.offset = 0;
  }
}
