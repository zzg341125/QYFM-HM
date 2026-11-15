export interface FileDescriptorCopyBridge {
  openRead(path: string): number;
  openWrite(uri: string): number;
  sizeOf(fd: number): number;
  read(fd: number, buffer: ArrayBuffer): number;
  write(fd: number, buffer: ArrayBuffer): void;
  close(fd: number): void;
}

export function copyBinaryFileToDocument(
  bridge: FileDescriptorCopyBridge,
  sourcePath: string,
  destinationUri: string
): number {
  const sourceFd = bridge.openRead(sourcePath);
  let destinationFd = -1;
  let copied = 0;
  try {
    destinationFd = bridge.openWrite(destinationUri);
    const size = bridge.sizeOf(sourceFd);
    const buffer = new ArrayBuffer(64 * 1024);
    while (copied < size) {
      const readLength = bridge.read(sourceFd, buffer);
      if (readLength <= 0) {
        break;
      }
      bridge.write(destinationFd, buffer.slice(0, readLength));
      copied += readLength;
    }
    return copied;
  } finally {
    if (destinationFd >= 0) {
      bridge.close(destinationFd);
    }
    bridge.close(sourceFd);
  }
}
