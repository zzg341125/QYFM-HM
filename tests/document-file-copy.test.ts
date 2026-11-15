import assert from 'node:assert/strict';
import test from 'node:test';
import { copyBinaryFileToDocument } from '../entry/src/main/ets/utils/DocumentFileCopy.ts';
import type { FileDescriptorCopyBridge } from '../entry/src/main/ets/utils/DocumentFileCopy.ts';

test('copies a sandbox file to a document picker URI through file descriptors', () => {
  const source = new Uint8Array([0x51, 0x59, 0x46, 0x4d, 0x31, 0x30, 0x31, 0x36]);
  const written: number[] = [];
  const closed: number[] = [];
  let readOffset = 0;
  const bridge: FileDescriptorCopyBridge = {
    openRead: (path: string): number => {
      assert.equal(path, '/data/files/update.app');
      return 11;
    },
    openWrite: (uri: string): number => {
      assert.equal(uri, 'file://docs/storage/Users/Download/update.app');
      return 22;
    },
    sizeOf: (fd: number): number => {
      assert.equal(fd, 11);
      return source.length;
    },
    read: (fd: number, buffer: ArrayBuffer): number => {
      assert.equal(fd, 11);
      const count = Math.min(3, source.length - readOffset);
      new Uint8Array(buffer).set(source.slice(readOffset, readOffset + count));
      readOffset += count;
      return count;
    },
    write: (fd: number, buffer: ArrayBuffer): void => {
      assert.equal(fd, 22);
      written.push(...Array.from(new Uint8Array(buffer)));
    },
    close: (fd: number): void => {
      closed.push(fd);
    }
  };

  const copied = copyBinaryFileToDocument(
    bridge,
    '/data/files/update.app',
    'file://docs/storage/Users/Download/update.app'
  );

  assert.equal(copied, source.length);
  assert.deepEqual(written, Array.from(source));
  assert.deepEqual(closed, [22, 11]);
});
