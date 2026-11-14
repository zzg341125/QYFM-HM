import assert from 'node:assert/strict';
import test from 'node:test';
import {
  buildUpdateFileName,
  isNewerVersion,
  installUtdForFileName,
  selectInstallAsset
} from '../entry/src/main/ets/utils/UpdateModel.ts';

test('compares multi-digit semantic versions numerically', () => {
  assert.equal(isNewerVersion('harmony-v1.0.10', '1.0.4'), true);
  assert.equal(isNewerVersion('harmony-v1.0.4', '1.0.4'), false);
  assert.equal(isNewerVersion('harmony-v1.0.3', '1.0.4'), false);
});

test('prefers the signed APP package and otherwise selects a signed HAP', () => {
  const asset = selectInstallAsset([
    { name: 'QYFM-HM-source.zip', browser_download_url: 'https://example.com/source.zip', size: 100 },
    { name: 'QYFM-HM-unsigned.hap', browser_download_url: 'https://example.com/unsigned.hap', size: 200 },
    { name: 'QYFM-HM-signed.hap', browser_download_url: 'https://example.com/signed.hap', size: 300 },
    { name: 'QYFM-HM-signed.app', browser_download_url: 'https://example.com/signed.app', size: 400 }
  ]);

  assert.equal(asset?.name, 'QYFM-HM-signed.app');
  assert.equal(asset?.browser_download_url, 'https://example.com/signed.app');
  assert.equal(installUtdForFileName('QYFM-HM-signed.app'), 'openharmony.package');
  assert.equal(installUtdForFileName('QYFM-HM-signed.hap'), 'openharmony.hap');
});

test('creates a safe local HAP filename from the selected asset', () => {
  assert.equal(
    buildUpdateFileName('harmony-v1.0.5', '../../QYFM HM signed.hap'),
    'QYFM-HM-signed.hap'
  );
});
