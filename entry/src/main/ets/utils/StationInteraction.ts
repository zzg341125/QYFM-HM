export type StationRowAction = 'play';
export type StationSwipeAction = 'edit' | 'delete';

export function stationRowTapAction(editMode: boolean): StationRowAction {
  return 'play';
}

export function stationSwipeActions(editMode: boolean): StationSwipeAction[] {
  return editMode ? ['edit', 'delete'] : [];
}
