export function parseIcyMetaint(headers: Object): number {
  const record = headers as Record<string, Object>;
  const keys = Object.keys(record);
  for (const key of keys) {
    if (key.toLowerCase() === 'icy-metaint') {
      const value = Number(record[key]);
      return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
    }
  }
  return 0;
}

export function parseIcyMetaintFromHeaderText(headers: string): number {
  const match = headers.match(/(?:^|\r\n)icy-metaint\s*:\s*(\d+)/i);
  return match === null ? 0 : Math.max(0, Math.floor(Number(match[1])));
}

export interface HttpEndpoint {
  host: string;
  port: number;
  path: string;
  hostHeader: string;
}

export function parseHttpEndpoint(url: string): HttpEndpoint | undefined {
  const match = url.trim().match(/^http:\/\/([^/:?#]+)(?::(\d+))?([^#]*)/i);
  if (match === null) {
    return undefined;
  }
  const host = match[1];
  const port = match[2] === undefined ? 80 : Number(match[2]);
  if (!Number.isFinite(port) || port <= 0 || port > 65535) {
    return undefined;
  }
  const path = match[3].length === 0 ? '/' : match[3];
  return {
    host: host,
    port: port,
    path: path,
    hostHeader: port === 80 ? host : `${host}:${port}`
  };
}

export function isProgressiveMp3Url(url: string): boolean {
  const path = url.trim().toLowerCase().split(/[?#]/)[0];
  return path.endsWith('.mp3');
}

function concatBytes(left: Uint8Array, right: Uint8Array): Uint8Array {
  if (left.length === 0) {
    return right.slice();
  }
  if (right.length === 0) {
    return left.slice();
  }
  const joined = new Uint8Array(left.length + right.length);
  joined.set(left, 0);
  joined.set(right, left.length);
  return joined;
}

function findCrlf(data: Uint8Array, start: number): number {
  for (let index = start; index + 1 < data.length; index++) {
    if (data[index] === 13 && data[index + 1] === 10) {
      return index;
    }
  }
  return -1;
}

function ascii(data: Uint8Array): string {
  let value = '';
  data.forEach((byte: number) => {
    value += String.fromCharCode(byte);
  });
  return value;
}

export class HttpChunkDecoder {
  private buffered: Uint8Array = new Uint8Array(0);
  private chunkRemaining: number = -1;
  private ended: boolean = false;

  push(data: Uint8Array): Uint8Array {
    this.buffered = concatBytes(this.buffered, data);
    const output: Uint8Array[] = [];
    while (!this.ended) {
      if (this.chunkRemaining < 0) {
        const lineEnd = findCrlf(this.buffered, 0);
        if (lineEnd < 0) {
          break;
        }
        const line = ascii(this.buffered.slice(0, lineEnd)).split(';')[0].trim();
        const size = Number.parseInt(line, 16);
        if (!Number.isFinite(size) || size < 0) {
          break;
        }
        this.buffered = this.buffered.slice(lineEnd + 2);
        if (size === 0) {
          this.ended = true;
          this.buffered = new Uint8Array(0);
          break;
        }
        this.chunkRemaining = size;
      }
      if (this.buffered.length < this.chunkRemaining + 2) {
        break;
      }
      output.push(this.buffered.slice(0, this.chunkRemaining));
      this.buffered = this.buffered.slice(this.chunkRemaining + 2);
      this.chunkRemaining = -1;
    }
    return output.reduce(
      (result: Uint8Array, chunk: Uint8Array): Uint8Array => concatBytes(result, chunk),
      new Uint8Array(0)
    );
  }

  isEnded(): boolean {
    return this.ended;
  }
}

export class IcyMetadataStripper {
  private metaint: number = 0;
  private audioRemaining: number = 0;
  private metadataRemaining: number = 0;

  configure(metaint: number): void {
    this.metaint = metaint > 0 ? Math.floor(metaint) : 0;
    this.audioRemaining = this.metaint;
    this.metadataRemaining = 0;
  }

  strip(data: Uint8Array): Uint8Array {
    if (this.metaint <= 0) {
      return data.slice();
    }
    const output = new Uint8Array(data.length);
    let written = 0;
    for (let index = 0; index < data.length; index++) {
      if (this.metadataRemaining > 0) {
        this.metadataRemaining--;
        continue;
      }
      if (this.audioRemaining <= 0) {
        this.metadataRemaining = data[index] * 16;
        this.audioRemaining = this.metaint;
        continue;
      }
      output[written] = data[index];
      written++;
      this.audioRemaining--;
    }
    return output.slice(0, written);
  }
}
