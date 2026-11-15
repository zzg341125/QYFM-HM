export interface UpdateArchiveFileSystem {
  createDirectory(directory: string): void;
  decompress(zipPath: string, outputDir: string): Promise<void>;
  list(directory: string): string[];
}

export async function extractAppPackage(
  fileSystem: UpdateArchiveFileSystem,
  zipPath: string,
  outputDir: string
): Promise<string> {
  fileSystem.createDirectory(outputDir);
  await fileSystem.decompress(zipPath, outputDir);
  const appFile = fileSystem.list(outputDir)
    .find((name: string) => name.toLowerCase().endsWith('.app'));
  if (appFile === undefined) {
    throw new Error('更新压缩包中没有 APP 安装包');
  }
  return `${outputDir.replace(/[\\/]+$/, '')}/${appFile}`;
}
