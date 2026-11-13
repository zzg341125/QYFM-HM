import assert from 'node:assert/strict';
import test from 'node:test';
import {
  backupDirectoryUrl,
  buildVersionedBackupFileName,
  buildRemoteFileUrl,
  mergeWebDavBackupEntries,
  orderStationsByBackup,
  parseWebDavBackupManifest
} from '../entry/src/main/ets/utils/BackupModel.ts';

test('creates a UTC timestamped backup name instead of overwriting one file', () => {
  const fileName = buildVersionedBackupFileName(
    'qyfm-backup.json',
    new Date('2026-11-14T01:02:03.004Z')
  );

  assert.equal(fileName, 'qyfm-backup-20261114-010203-004.json');
});

test('turns a legacy JSON URL into its containing WebDAV directory', () => {
  assert.equal(
    backupDirectoryUrl('https://dav.example.com/radio/qyfm-backup.json'),
    'https://dav.example.com/radio'
  );
  assert.equal(
    buildRemoteFileUrl('https://dav.example.com/radio/', '备份 file.json'),
    'https://dav.example.com/radio/%E5%A4%87%E4%BB%BD%20file.json'
  );
});

test('lists the newest unique WebDAV backup first', () => {
  const entries = mergeWebDavBackupEntries(
    [
      { fileName: 'backup-old.json', exportedAt: '2026-11-12T00:00:00.000Z', stationCount: 2, appVersion: '1.0.1' },
      { fileName: 'backup-new.json', exportedAt: '2026-11-14T00:00:00.000Z', stationCount: 3, appVersion: '1.0.1' }
    ],
    {
      fileName: 'backup-old.json',
      exportedAt: '2026-11-13T00:00:00.000Z',
      stationCount: 4,
      appVersion: '1.0.2'
    }
  );

  assert.deepEqual(entries.map((entry) => entry.fileName), ['backup-new.json', 'backup-old.json']);
  assert.equal(entries[1].stationCount, 4);
});

test('parses only valid backup entries from a remote manifest', () => {
  const manifest = parseWebDavBackupManifest(JSON.stringify({
    schemaVersion: 1,
    backups: [
      { fileName: 'valid.json', exportedAt: '2026-11-14T00:00:00.000Z', stationCount: 3, appVersion: '1.0.2' },
      { fileName: '../escape.json', exportedAt: '2026-11-14T00:00:00.000Z', stationCount: 3, appVersion: '1.0.2' }
    ]
  }));

  assert.deepEqual(manifest.backups.map((entry) => entry.fileName), ['valid.json']);
});

test('rejects a malformed remote manifest instead of silently replacing its history', () => {
  assert.throws(
    () => parseWebDavBackupManifest(JSON.stringify({ schemaVersion: 99, backups: [] })),
    /受支持/
  );
});

test('restores explicit playlist order and appends missing stations once', () => {
  const ordered = orderStationsByBackup(
    [
      { id: 'a', name: 'A' },
      { id: 'b', name: 'B' },
      { id: 'c', name: 'C' }
    ],
    ['c', 'a', 'c', 'missing']
  );

  assert.deepEqual(ordered.map((station) => station.id), ['c', 'a', 'b']);
});
