const PRIMING_DECODE_MAX_BYTES: number = 4096;
const OUTPUT_SAMPLE_RATE: number = 48000;
const OUTPUT_CHANNELS: number = 2;
const OUTPUT_BYTES_PER_SAMPLE: number = 4;
const DECODE_BATCH_BYTES: number = 8192;

export function shouldPrimeDecoder(decoderJustCreated: boolean, inputBytes: number): boolean {
  return decoderJustCreated && inputBytes > 0 && inputBytes <= PRIMING_DECODE_MAX_BYTES;
}

export function shouldReconnectAfterPause(paused: boolean): boolean {
  return paused || !paused;
}

export function shouldDecodeBatchedInput(queuedBytes: number): boolean {
  return queuedBytes >= DECODE_BATCH_BYTES;
}


export function pcmStartWatermark(fastStart: boolean, managedHls: boolean = false): number {
  const seconds = managedHls ? 6 : (fastStart ? 6 : 8);
  return Math.round(
    OUTPUT_SAMPLE_RATE * OUTPUT_CHANNELS * OUTPUT_BYTES_PER_SAMPLE * seconds
  );
}

export function shouldStartPcmRenderer(
  fastStart: boolean,
  queuedBytes: number,
  managedHls: boolean = false
): boolean {
  return queuedBytes >= pcmStartWatermark(fastStart, managedHls);
}

export function pcmQueueDurationSeconds(managedHls: boolean): number {
  return 12;
}
