export type Binary = ArrayBuffer | ArrayBufferView

export interface JsBayError extends Error {
  readonly status?: number
}

export type HostValue = undefined | null | boolean | number | string | Error | Binary | HostValue[] | { [key: string]: HostValue }

export type HostCallback = (...args: HostValue[]) => HostValue | void
export type AsyncHostCallback = (...args: HostValue[]) => HostValue | void | PromiseLike<HostValue | void>

export interface EngineOptions {
  instanceId?: number
}

export interface Engine {
  evaluate(source: string, filename?: string): HostValue
  evaluateAsync(source: string, filename?: string): Promise<HostValue>
  bind(name: string, callback: HostCallback): void
  bindAsync(name: string, callback: AsyncHostCallback): void
  close(): void
}

export const Engine: {
  create(options?: EngineOptions): Engine
}
