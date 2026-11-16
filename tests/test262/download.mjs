import { setTimeout } from 'node:timers/promises';

const transientStatuses = new Set([408, 429, 500, 502, 503, 504]);

export async function downloadSource(url) {
  let lastError;
  for (let attempt = 1; attempt <= 3; attempt++) {
    let response;
    try {
      response = await fetch(url, { signal: AbortSignal.timeout(30000) });
      if (response.ok) return Buffer.from(await response.arrayBuffer());
    } catch (error) {
      lastError = error;
    }
    if (response && !response.ok) {
      await response.body?.cancel();
      lastError = new Error(`HTTP ${response.status}`);
      if (!transientStatuses.has(response.status)) throw new Error(`Download ${url}: ${lastError.message}`, { cause: lastError });
    }
    if (attempt < 3) await setTimeout(250 * attempt);
  }
  const detail = lastError?.cause?.code || lastError?.code || lastError?.message || 'unknown transport error';
  throw new Error(`Download ${url} failed after 3 attempts: ${detail}`, { cause: lastError });
}
