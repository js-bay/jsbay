export type Binary = ArrayBuffer | ArrayBufferView

export type JsBayStatusCode = 'JSBAY_OK' | 'JSBAY_EXCEPTION' | 'JSBAY_INVALID_ARGUMENT' | 'JSBAY_WRONG_THREAD' | 'JSBAY_INSTANCE_NOT_FOUND' | 'JSBAY_STALE_VALUE' | 'JSBAY_OUT_OF_MEMORY' | 'JSBAY_UNSUPPORTED' | 'JSBAY_LOOP_FAILED'

export interface JsBayError extends Error {
  readonly status?: number
  readonly code?: JsBayStatusCode
}

export type HostValue = undefined | null | boolean | number | string | Error | Binary | HostValue[] | { [key: string]: HostValue }
export type NodeValueType = 'undefined' | 'null' | 'boolean' | 'number' | 'string' | 'object' | 'array' | 'function' | 'symbol' | 'bigint'

export interface NodeValue {
  retain(): NodeValue
  close(): void
  type(): NodeValueType
  toHost(): HostValue
  toBool(): boolean
  toNumber(): number
  toString(): string
  toJson(): string
  copyBuffer(): ArrayBuffer
  get(key: string): NodeValue
  set(key: string, value: HostValue | NodeValue): this
  call(thisValue: HostValue | NodeValue, ...args: (HostValue | NodeValue)[]): NodeValue
  construct(...args: (HostValue | NodeValue)[]): NodeValue
  has(key: string): boolean
  delete(key: string): boolean
  keys(): NodeValue
  instanceOf(constructor: NodeValue): boolean
}

export type HostCallback = (...args: HostValue[]) => HostValue | void
export type AsyncHostCallback = (...args: HostValue[]) => HostValue | void | PromiseLike<HostValue | void>

export interface EngineOptions {
  instanceId?: number
  limits?: ResourceLimits
  onLog?: (instanceId: number, level: number, message: string) => void
  onEvent?: (event: EngineEvent) => void
}

export interface ControlToken { instanceId: number; generation: bigint }
export interface ShutdownStatus { phase: 0 | 1 | 2 | 3 | 4; remainingMs: bigint }
export interface EngineEvent { kind: number; instanceId: number; status: number; detail: bigint; message: string | null }
export interface ResourceLimits { maxTimers: number | bigint; maxTsfnHandles: number | bigint; maxPendingCalls: number | bigint; maxPendingBytes: number | bigint; maxPendingTasks: number | bigint }
export interface SubmissionResult { status: 'completed' | 'exception' | 'cancelled'; error: string | null }
export interface EngineSnapshot { instanceId: number; generation: bigint; ownerThreadId: bigint; loopMode: number; flags: number; admissionClass: 'foreground' | 'background'; timersReserved: bigint; timersRegistered: bigint; scriptTasksQueued: bigint; nativeTasksQueued: bigint; pendingBytes: bigint; limits: { maxTimers: bigint; maxPendingTasks: bigint; maxPendingBytes: bigint } }

export interface EvaluateOptions {
  cacheDir?: string
  cacheVersion?: string
}

export interface EngineCapabilities {
  backend: string
  flags: number
  sourceDebugger: boolean
  memoryLimit: boolean
  bytecode: boolean
  bytecodeCache: boolean
  executionLimit: boolean
}

export interface ResourceUsage {
  timers: bigint
  tsfn_handles: bigint
  pending_calls: bigint
  native_tasks: bigint
  script_tasks: bigint
  pending_bytes: bigint
  max_timers: bigint
  max_tsfn_handles: bigint
  max_pending_calls: bigint
  max_pending_bytes: bigint
  max_pending_tasks: bigint
}

export interface MemoryUsage {
  malloc_count: bigint
  malloc_size: bigint
  malloc_limit: bigint
  memory_used_count: bigint
  memory_used_size: bigint
  atom_count: bigint
  atom_size: bigint
  obj_count: bigint
  obj_size: bigint
  shape_count: bigint
}

export interface Engine {
  readonly id: number
  readonly generation: bigint
  readonly controlToken: ControlToken
  evaluate(source: string, filename?: string, options?: EvaluateOptions): HostValue
  evaluateAsync(source: string, filename?: string, options?: EvaluateOptions): Promise<HostValue>
  evaluateValue(source: string, filename?: string, options?: EvaluateOptions): NodeValue
  bind(name: string, callback: HostCallback): void
  bindAsync(name: string, callback: AsyncHostCallback): void
  close(): void
  closeAsync(): Promise<void>
  setExecutionTimeLimit(milliseconds: number): void
  setExecutionBudget(milliseconds: number): void
  setMemoryLimit(bytes: number): void
  inspectorStart(port: number): number
  inspectorStop(): void
  resourceUsage(): ResourceUsage
  memoryUsage(): MemoryUsage
  requestInterrupt(): boolean
  cancel(): boolean
  beginShutdown(graceMs: number | bigint): boolean
  shutdownStatus(): ShutdownStatus | undefined
  suspend(): boolean
  resume(): boolean
  isSuspended(): boolean
  runGc(): void
  lastCacheHit(): boolean
  setResourceLimits(limits: ResourceLimits): boolean
  setAdmissionClass(value: 'foreground' | 'background'): boolean
  admissionClass(): 'foreground' | 'background'
  snapshot(): EngineSnapshot | undefined
  setLogHandler(callback: ((instanceId: number, level: number, message: string) => void) | null): boolean
  setEventHandler(callback: ((event: EngineEvent) => void) | null): boolean
  postScript(source: string, filename?: string): Promise<SubmissionResult>
  postFence(options?: { sealShutdown?: boolean }): Promise<SubmissionResult>
  value(hostValue: HostValue | NodeValue): NodeValue
  global(): NodeValue
  object(): NodeValue
  array(): NodeValue
}

export const Engine: {
  create(options?: EngineOptions): Engine
  capabilities(): EngineCapabilities
  requestInterrupt(token: ControlToken): boolean
  cancel(token: ControlToken): boolean
  beginShutdown(token: ControlToken, graceMs: number | bigint): boolean
  shutdownStatus(token: ControlToken): ShutdownStatus | undefined
  listEngines(): number[]
  globalResourceUsage(): Record<string, bigint>
}
