export interface BluetoothBinding {
  deviceId: string;
  deviceName: string;
  autoPlay: boolean;
  lastConnectedAt: number;
}

export function rememberBluetoothBinding(
  bindings: BluetoothBinding[],
  deviceId: string,
  deviceName: string,
  now: number
): BluetoothBinding[] {
  const normalizedId = deviceId.trim();
  if (normalizedId.length === 0) {
    return bindings.slice(0, 3);
  }
  const existing = bindings.find((binding: BluetoothBinding): boolean =>
    binding.deviceId === normalizedId);
  const next: BluetoothBinding = {
    deviceId: normalizedId,
    deviceName: deviceName.trim(),
    autoPlay: existing?.autoPlay ?? false,
    lastConnectedAt: now
  };
  return bindings
    .filter((binding: BluetoothBinding): boolean => binding.deviceId !== normalizedId)
    .concat([next])
    .sort((left: BluetoothBinding, right: BluetoothBinding): number =>
      right.lastConnectedAt - left.lastConnectedAt)
    .slice(0, 3);
}

export function findBluetoothBinding(
  bindings: BluetoothBinding[],
  deviceId: string
): BluetoothBinding | undefined {
  return bindings.find((binding: BluetoothBinding): boolean => binding.deviceId === deviceId);
}
