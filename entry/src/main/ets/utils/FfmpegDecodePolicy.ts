const PRIMING_DECODE_MAX_BYTES: number = 4096;
const OUTPUT_SAMPLE_RATE: number = 48000;
const OUTPUT_CHANNELS: number = 2;
const OUTPUT_BYTES_PER_SAMPLE: number = 4;

export function shouldPrimeDecoder(decoderJustCreated: boolean, inputBytes: number): boolean {
  return decoderJustCreated && inputBytes > 0 && inputBytes <= PRIMING_DECODE_MAX_BYTES;
}

export function shouldReconnectAfterPause(paused: boolean): boolean {
  return paused || !paused;
}

export function pcmStartWatermark(fastStart: boolean): number {
  const seconds = fastStart ? 0.25 : 0.6;
  return Math.round(
    OUTPUT_SAMPLE_RATE * OUTPUT_CHANNELS * OUTPUT_BYTES_PER_SAMPLE * seconds
  );
}

export function shouldStartPcmRenderer(fastStart: boolean, queuedBytes: number): boolean {
  return queuedBytes >= pcmStartWatermark(fastStart);
}

export function pcmQueueDurationSeconds(managedHls: boolean): number {
  return managedHls ? 12 : 3;
}
