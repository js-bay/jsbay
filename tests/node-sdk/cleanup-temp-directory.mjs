import { rm } from 'node:fs/promises'

export async function cleanupTempDirectory(path, operationError, remove = rm, report = message => console.error(message)) {
  try {
    await remove(path, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 })
  } catch (cleanupError) {
    if (!operationError) throw cleanupError
    report(`Temporary directory cleanup failed: ${cleanupError?.message ?? cleanupError}`)
  }
}
