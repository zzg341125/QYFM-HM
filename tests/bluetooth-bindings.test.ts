import assert from 'node:assert/strict';
import test from 'node:test';
import {
  findBluetoothBinding,
  forgetBluetoothBinding,
  rememberBluetoothBinding,
  replaceBluetoothBinding
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

test('does not evict a saved Bluetooth device when a fourth device connects', () => {
  let bindings = rememberBluetoothBinding([], 'oldest', 'Oldest', 1000);
  bindings = rememberBluetoothBinding(bindings, 'middle', 'Middle', 2000);
  bindings = rememberBluetoothBinding(bindings, 'newest', 'Newest', 3000);
  const beforeFourth = bindings;
  bindings = rememberBluetoothBinding(bindings, 'fourth', 'Fourth', 4000);

  assert.deepEqual(bindings.map((binding) => binding.deviceId), [
    'newest',
    'middle',
    'oldest'
  ]);
  assert.deepEqual(bindings, beforeFourth);
  assert.equal(findBluetoothBinding(bindings, 'fourth'), undefined);
  assert.equal(findBluetoothBinding(bindings, 'newest')?.deviceName, 'Newest');
});

test('forgets one Bluetooth binding so the device can be bound again', () => {
  const bindings = forgetBluetoothBinding([{
    deviceId: 'device-a',
    deviceName: 'Car Audio',
    autoPlay: true,
    lastConnectedAt: 1000
  }, {
    deviceId: 'device-b',
    deviceName: 'Headset',
    autoPlay: false,
    lastConnectedAt: 900
  }], ' device-a ');

  assert.deepEqual(bindings, [{
    deviceId: 'device-b',
    deviceName: 'Headset',
    autoPlay: false,
    lastConnectedAt: 900
  }]);
  assert.equal(findBluetoothBinding(bindings, 'device-a'), undefined);
});

test('replaces a deleted binding with the pending fourth device', () => {
  const bindings = replaceBluetoothBinding([{
    deviceId: 'device-a',
    deviceName: 'Car Audio',
    autoPlay: true,
    lastConnectedAt: 3000
  }, {
    deviceId: 'device-b',
    deviceName: 'Headset',
    autoPlay: false,
    lastConnectedAt: 2000
  }, {
    deviceId: 'device-c',
    deviceName: 'Speaker',
    autoPlay: true,
    lastConnectedAt: 1000
  }], 'device-a', {
    deviceId: 'device-new',
    deviceName: 'New Headset',
    autoPlay: false,
    lastConnectedAt: 4000
  });

  assert.deepEqual(bindings.map((binding) => binding.deviceId), [
    'device-new',
    'device-b',
    'device-c'
  ]);
  assert.equal(findBluetoothBinding(bindings, 'device-a'), undefined);
  assert.equal(findBluetoothBinding(bindings, 'device-new')?.autoPlay, false);
});
