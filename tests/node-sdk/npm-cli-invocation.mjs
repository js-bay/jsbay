import { win32 } from 'node:path'

export function getNpmInvocation({ cli = process.env.NPM_CLI, platform = process.platform, execPath = process.execPath } = {}) {
  if (cli) return { command: cli, args: [] }
  if (platform === 'win32') {
    return {
      command: execPath,
      args: [win32.join(win32.dirname(execPath), 'node_modules', 'npm', 'bin', 'npm-cli.js')],
    }
  }
  return { command: 'npm', args: [] }
}
