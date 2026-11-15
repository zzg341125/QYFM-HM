import assert from 'node:assert/strict';
import test from 'node:test';
import { buildFileManagerTarget } from '../entry/src/main/ets/utils/UpdateInstallerModel.ts';

test('targets the installed HarmonyOS file manager directory entry', () => {
  assert.deepEqual(
    buildFileManagerTarget('file://docs/storage/Users/Download'),
    {
      bundleName: 'com.huawei.hmos.files',
      abilityName: 'EntryAbility',
      uri: 'filemanager://openDirectory',
      directoryUri: 'file://docs/storage/Users/Download'
    }
  );
});
