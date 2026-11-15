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

export function isProgressiveMp3Url(url: string): boolean {
  const path = url.trim().toLowerCase().split(/[?#]/)[0];
  return path.endsWith('.mp3');
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
