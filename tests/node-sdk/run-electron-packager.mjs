import { execFile } from 'node:child_process'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { promisify } from 'node:util'

const run = promisify(execFile)
const resultPrefix = 'JSBAY_ELECTRON_PACKAGER_RESULT='
const childScript = fileURLToPath(new URL('./electron-packager-child.mjs', import.meta.url))

export async function packageElectronApp(packagerEntry, appDir, outputDir, electronVersion, runCommand = run) {
  const { stdout } = await runCommand(process.execPath, [
    childScript,
    pathToFileURL(packagerEntry).href,
    appDir,
    outputDir,
    electronVersion,
  ], { windowsHide: true, maxBuffer: 32 * 1024 * 1024 })
  const resultLine = stdout.split(/\r?\n/).findLast(line => line.startsWith(resultPrefix))
  if (!resultLine) throw new Error('Electron Packager child exited without reporting its bundle paths')
  return JSON.parse(resultLine.slice(resultPrefix.length))
}
