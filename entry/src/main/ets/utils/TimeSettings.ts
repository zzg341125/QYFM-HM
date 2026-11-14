export function normalizeResumeWindowMinutes(value: number): number {
  if (!Number.isFinite(value)) {
    return 120;
  }
  return Math.min(1440, Math.max(5, Math.round(value)));
}

function twoDigits(value: number): string {
  return value.toString().padStart(2, '0');
}

export function formatSleepTimerEnd(now: Date, minutes: number): string {
  const end = new Date(now.getTime() + Math.max(0, minutes) * 60 * 1000);
  return `将于 ${twoDigits(end.getHours())}:${twoDigits(end.getMinutes())} 停止播放`;
}
