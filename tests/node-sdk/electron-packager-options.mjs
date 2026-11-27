export const electronExecutableName = 'JsBaySmoke'

export function createElectronPackagerOptions(appDir, outputDir, electronVersion) {
  return {
    dir: appDir,
    name: electronExecutableName,
    executableName: electronExecutableName,
    platform: 'win32',
    arch: 'x64',
    electronVersion,
    out: outputDir,
    overwrite: true,
    prune: false,
    asar: { unpack: '**/*.node' },
  }
}
