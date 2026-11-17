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
  if (existing === undefined && bindings.length >= 3) {
    return bindings.slice(0, 3);
  }
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

export function forgetBluetoothBinding(
  bindings: BluetoothBinding[],
  deviceId: string
): BluetoothBinding[] {
  const normalizedId = deviceId.trim();
  return bindings.filter((binding: BluetoothBinding): boolean =>
    binding.deviceId !== normalizedId);
}

export function replaceBluetoothBinding(
  bindings: BluetoothBinding[],
  deviceIdToForget: string,
  replacement: BluetoothBinding | undefined
): BluetoothBinding[] {
  const remaining = forgetBluetoothBinding(bindings, deviceIdToForget);
  return replacement === undefined
    ? remaining
    : rememberBluetoothBinding(
      remaining,
      replacement.deviceId,
      replacement.deviceName,
      replacement.lastConnectedAt
    );
}
