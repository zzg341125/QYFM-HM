import assert from 'node:assert/strict';
import test from 'node:test';
import {
  findBluetoothBinding,
  rememberBluetoothBinding
} from '../entry/src/main/ets/utils/BluetoothBindings.ts';

test('remembers a new Bluetooth device without enabling auto-play implicitly', () => {
  const bindings = rememberBluetoothBinding([], 'device-a', 'Car Audio', 1000);
  assert.deepEqual(bindings, [{
    deviceId: 'device-a',
    deviceName: 'Car Audio',
    autoPlay: false,
    lastConnectedAt: 1000
  }]);
});

test('keeps an existing Bluetooth auto-play choice when reconnecting', () => {
  const bindings = rememberBluetoothBinding([{
    deviceId: 'device-a',
    deviceName: 'Old Name',
    autoPlay: true,
    lastConnectedAt: 1000
  }], 'device-a', 'New Name', 2000);
  assert.deepEqual(bindings, [{
    deviceId: 'device-a',
    deviceName: 'New Name',
    autoPlay: true,
    lastConnectedAt: 2000
  }]);
});

test('retains only the three most recently connected Bluetooth devices', () => {
  let bindings = rememberBluetoothBinding([], 'oldest', 'Oldest', 1000);
  bindings = rememberBluetoothBinding(bindings, 'middle', 'Middle', 2000);
  bindings = rememberBluetoothBinding(bindings, 'newest', 'Newest', 3000);
  bindings = rememberBluetoothBinding(bindings, 'fourth', 'Fourth', 4000);

  assert.deepEqual(bindings.map((binding) => binding.deviceId), [
    'fourth',
    'newest',
    'middle'
  ]);
  assert.equal(findBluetoothBinding(bindings, 'oldest'), undefined);
  assert.equal(findBluetoothBinding(bindings, 'newest')?.deviceName, 'Newest');
});
