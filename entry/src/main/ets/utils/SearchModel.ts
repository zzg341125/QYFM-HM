export interface SearchStationRef {
  id: string;
  streamUrl: string;
}

export function shouldShowSearchResults(query: string, resultCount: number): boolean {
  return query.trim().length > 0 && resultCount > 0;
}

export function isSearchStationAdded<T extends SearchStationRef>(
  stations: T[],
  station: SearchStationRef
): boolean {
  return stations.some((saved: T) =>
    saved.id === station.id || saved.streamUrl === station.streamUrl);
}
