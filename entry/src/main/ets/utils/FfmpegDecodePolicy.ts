const PRIMING_DECODE_MAX_BYTES: number = 4096;

export function shouldPrimeDecoder(decoderJustCreated: boolean, inputBytes: number): boolean {
  return decoderJustCreated && inputBytes > 0 && inputBytes <= PRIMING_DECODE_MAX_BYTES;
}
