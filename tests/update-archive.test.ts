import assert from 'node:assert/strict';
import test from 'node:test';
import { extractAppPackage } from '../entry/src/main/ets/utils/UpdateArchiveModel.ts';
import type { UpdateArchiveFileSystem } from '../entry/src/main/ets/utils/UpdateArchiveModel.ts';

test('creates the update extraction directory before decompressing the APP zip', async () => {
  const operations: string[] = [];
  const fileSystem: UpdateArchiveFileSystem = {
    createDirectory: (directory: string): void => {
      operations.push(`mkdir:${directory}`);
    },
    decompress: async (zipPath: string, outputDir: string): Promise<void> => {
      operations.push(`decompress:${zipPath}->${outputDir}`);
    },
    list: (directory: string): string[] => {
      operations.push(`list:${directory}`);
      return ['QYFM-HM-harmony-v1.0.15-signed.app'];
    }
  };

  const appPath = await extractAppPackage(
    fileSystem,
    '/data/files/update.app.zip',
    '/data/files/qyfm-update-123'
  );

  assert.deepEqual(operations, [
    'mkdir:/data/files/qyfm-update-123',
    'decompress:/data/files/update.app.zip->/data/files/qyfm-update-123',
    'list:/data/files/qyfm-update-123'
  ]);
  assert.equal(appPath, '/data/files/qyfm-update-123/QYFM-HM-harmony-v1.0.15-signed.app');
});

test('rejects an APP zip that has no installable APP package', async () => {
  const fileSystem: UpdateArchiveFileSystem = {
    createDirectory: (): void => {},
    decompress: async (): Promise<void> => {},
    list: (): string[] => ['readme.txt']
  };

  await assert.rejects(
    () => extractAppPackage(fileSystem, '/data/files/update.app.zip', '/data/files/output'),
    /APP 安装包/
  );
});
