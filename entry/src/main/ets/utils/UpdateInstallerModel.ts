export interface FileManagerTarget {
  bundleName: string;
  abilityName: string;
  uri: string;
  directoryUri: string;
}

export function buildFileManagerTarget(directoryUri: string): FileManagerTarget {
  return {
    bundleName: 'com.huawei.hmos.files',
    abilityName: 'EntryAbility',
    uri: 'filemanager://openDirectory',
    directoryUri: directoryUri
  };
}
