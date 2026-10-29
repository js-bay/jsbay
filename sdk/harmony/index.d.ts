/** Public ArkTS surface of the Harmony HAR. */
export declare enum ValueKind {
  Undefined,
  Null,
  Bool,
  Number,
  String,
  Object,
  Array,
  Function,
  Symbol,
  BigInt,
}

export declare enum JsBayStatus {
  Ok = 0,
  Exception = 1,
  InvalidArgument = 2,
  WrongThread = 3,
  InstanceNotFound = 4,
  StaleValue = 5,
  OutOfMemory = 6,
  Unsupported = 7,
  LoopFailed = 8,
}

export declare class JsBayStatusError extends Error {
  constructor(status: JsBayStatus, code?: string);
  readonly status: JsBayStatus;
  readonly code: string;
}

export type BinarySource = ArrayBuffer | DataView | Int8Array | Uint8Array | Uint8ClampedArray | Int16Array | Uint16Array | Int32Array | Uint32Array | Float32Array | Float64Array | BigInt64Array | BigUint64Array;

export declare class Value {
  private constructor();
  close(): void;
  retain(): Value;
  type(): ValueKind;
  toBool(): boolean;
  toNumber(): number;
  toUtf8(): ArrayBuffer;
  string(): string;
  toJson(): ArrayBuffer;
  copyBuffer(): ArrayBuffer;
  cacheHit(): boolean;
  get(key: string): Value;
  set(key: string, value: Value): void;
  call(thisValue: Value, args?: Value[]): Value;
  construct(args?: Value[]): Value;
  has(key: string): boolean;
  delete(key: string): boolean;
  keys(): Value;
  instanceOf(constructorValue: Value): boolean;
}

export type HostCallback = (thisValue: Value, args: Value[]) => Value;
export type SyncStarter = (requestId: bigint, thisValue: Value, args: Value[]) => void;

export declare class JsException extends Error {
  constructor(value: Value);
  readonly value: Value;
  describeAndClose(): string;
}

export declare interface ResourceLimits {
  maxTimers: number;
  maxTsfnHandles: number;
  maxPendingCalls: number;
  maxPendingBytes: number;
  maxPendingTasks: number;
}

export declare interface InstanceSnapshot {
  instanceId: number;
  generation: bigint;
  ownerThreadId: bigint;
  loopMode: number;
  flags: number;
  admissionClass: number;
  timersReserved: bigint;
  timersRegistered: bigint;
  scriptTasksQueued: bigint;
  nativeTasksQueued: bigint;
  pendingBytes: bigint;
  maxTimers: bigint;
  maxPendingTasks: bigint;
  maxPendingBytes: bigint;
}

export declare interface ResourceUsage {
  timers: bigint;
  tsfnHandles: bigint;
  pendingCalls: bigint;
  nativeTasks: bigint;
  scriptTasks: bigint;
  pendingBytes: bigint;
  maxTimers: bigint;
  maxTsfnHandles: bigint;
  maxPendingCalls: bigint;
  maxPendingBytes: bigint;
  maxPendingTasks: bigint;
}

export declare interface ResourceGlobalUsage {
  timers: bigint;
  tsfnHandles: bigint;
  pendingCalls: bigint;
  nativeTasks: bigint;
  scriptTasks: bigint;
  pendingBytes: bigint;
  maxTimers: bigint;
  maxTsfnHandles: bigint;
  maxPendingCalls: bigint;
  maxNativeTasks: bigint;
  maxScriptTasks: bigint;
  maxPendingBytes: bigint;
  fgHeadroomTimers: bigint;
  fgHeadroomTsfnHandles: bigint;
  fgHeadroomPendingCalls: bigint;
  fgHeadroomNativeTasks: bigint;
  fgHeadroomScriptTasks: bigint;
  fgHeadroomPendingBytes: bigint;
  bgEffectiveMaxTimers: bigint;
  bgEffectiveMaxTsfnHandles: bigint;
  bgEffectiveMaxPendingCalls: bigint;
  bgEffectiveMaxNativeTasks: bigint;
  bgEffectiveMaxScriptTasks: bigint;
  bgEffectiveMaxPendingBytes: bigint;
}

export declare interface MemoryUsage {
  mallocCount: bigint;
  mallocSize: bigint;
  mallocLimit: bigint;
  memoryUsedCount: bigint;
  memoryUsedSize: bigint;
  atomCount: bigint;
  atomSize: bigint;
  objCount: bigint;
  objSize: bigint;
  shapeCount: bigint;
}

export declare enum EngineEventKind {
  Log = 0,
  ExecutionInterrupted = 1,
  MemoryLimit = 2,
  LoopFailed = 3,
}

export type EventHandler = (kind: EngineEventKind, instanceId: number, status: number, detail: bigint, message: string | null) => void;

export declare class Engine {
  private constructor();
  static create(instanceId: number, limits?: ResourceLimits): Engine;
  static globalResourceUsage(): ResourceGlobalUsage;
  evaluate(source: string, filename: string, cacheDir?: string, cacheVersion?: string): Value;
  global(): Value;
  newString(value: string): Value;
  newNumber(value: number): Value;
  newBool(value: boolean): Value;
  undefined(): Value;
  null(): Value;
  newJson(value: string): Value;
  newError(message: string): Value;
  newObject(): Value;
  newArray(): Value;
  newArrayBuffer(value: BinarySource): Value;
  bind(name: string, callback: HostCallback): Value;
  bindSync(name: string, timeoutMs: bigint, starter: SyncStarter): Value;
  static completeSyncString(requestId: bigint, value: string): JsBayStatus;
  static completeSyncBytes(requestId: bigint, value: BinarySource): JsBayStatus;
  static rejectSync(requestId: bigint, message: string): JsBayStatus;
  static completeSync(requestId: bigint, outcome: JsBayStatus.Ok | JsBayStatus.Exception, kind: number, data: string | BinarySource): JsBayStatus;
  runLoop(): void;
  stopLoop(): boolean;
  suspendLoop(): boolean;
  resumeLoop(): boolean;
  isSuspended(): boolean;
  setAdmissionClass(cls: number): boolean;
  getAdmissionClass(): number;
  snapshot(): InstanceSnapshot | null;
  static listEngines(): number[];
  static snapshot(id: number): InstanceSnapshot | null;
  requestInterrupt(): boolean;
  clearInterrupt(): boolean;
  setExecutionTimeLimit(milliseconds: bigint): boolean;
  setMemoryLimit(bytes: bigint): boolean;
  setResourceLimits(limits: ResourceLimits): boolean;
  resourceUsage(): ResourceUsage;
  getMemoryUsage(): MemoryUsage;
  runGc(): boolean;
  inspectorStart(port: number): number;
  inspectorStop(): void;
  close(): void;
}
