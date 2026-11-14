export function moveListItem<T>(items: T[], from: number, to: number): T[] {
  const next = items.slice();
  if (from === to || from < 0 || to < 0 || from >= next.length || to >= next.length) {
    return next;
  }
  const removed = next.splice(from, 1);
  next.splice(to, 0, removed[0]);
  return next;
}
