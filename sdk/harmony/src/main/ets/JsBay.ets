import native from 'libjsbay_harmony.so';
import util from '@ohos.util';

type NativeValue = object;
type NativeEngine = object;

export enum ValueKind {
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
/** Numeric values match jsbay_status_t in the public C ABI. */
export enum JsBayStatus {
  Ok,
  Exception,
  InvalidArgument,
  WrongThread,
  InstanceNotFound,
  StaleValue,
  OutOfMemory,
  Unsupported,
  LoopFailed,
}
export type BinarySource = ArrayBuffer | DataView | Int8Array | Uint8Array | Uint8ClampedArray | Int16Array | Uint16Array | Int32Array | Uint32Array | Float32Array | Float64Array | BigInt64Array | BigUint64Array;

function statusCode(status: JsBayStatus): string {
  return ['JSBAY_OK', 'JSBAY_EXCEPTION', 'JSBAY_INVALID_ARGUMENT', 'JSBAY_WRONG_THREAD', 'JSBAY_INSTANCE_NOT_FOUND', 'JSBAY_STALE_VALUE', 'JSBAY_OUT_OF_MEMORY', 'JSBAY_UNSUPPORTED', 'JSBAY_LOOP_FAILED'][status];
}

/* N-API encodes a lone UTF-16 surrogate as replacement text. Reject it before crossing the ABI so public text inputs are lossless UTF-8. */
function requireWellFormedText(value: string): string {
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      const next = index + 1 < value.length ? value.charCodeAt(index + 1) : 0;
      if (next < 0xDC00 || next > 0xDFFF) {
        throw new JsBayStatusError(JsBayStatus.InvalidArgument);
      }
      index += 1;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      throw new JsBayStatusError(JsBayStatus.InvalidArgument);
    }
  }

  return value;
}

/** A non-JavaScript C ABI failure with its stable jsbay_status_t value. */
export class JsBayStatusError extends Error {
  readonly status: JsBayStatus;
  readonly code: string;
  constructor(status: JsBayStatus, code?: string) {
    super(code === undefined ? statusCode(status) : code);
    this.status = status;
    this.code = code === undefined ? statusCode(status) : code;
  }
}

/** A live JS value owned by one Engine. Call close on the Engine owner Worker. */
export class Value {
  private raw: NativeValue;
  private readonly borrowed: boolean;
  private closed: boolean = false;
  private loopTimer: number | undefined = undefined;
  private constructor(raw: NativeValue, borrowed: boolean = false) {
    this.raw = raw;
    this.borrowed = borrowed;
  }
  static fromNative(raw: NativeValue, borrowed: boolean = false): Value {
    return new Value(raw, borrowed);
  }
  native(): NativeValue {
    if (this.closed) {
      throw new JsBayStatusError(JsBayStatus.StaleValue);
    }

    return this.raw;
  }
  /** @internal Rejects borrowed, stale, and wrong-thread values before consuming exception text. */
  requireOwnedForConsume(): void {
    this.type();
    if (this.borrowed) {
      throw new JsBayStatusError(JsBayStatus.InvalidArgument);
    }
  }
  close(): void {
    if (this.closed) {
      return;
    }
    try {
      invoke((): void => {
        native.release(this.raw);
      });
      this.closed = true;
    } catch (cause) {
      /* Engine destruction revokes all owned C handles. Closing such a wrapper remains idempotent even though the native release reports stale. */
      if (!this.borrowed && cause instanceof JsBayStatusError && cause.status === JsBayStatus.StaleValue) {
        this.closed = true;

        return;
      }
      if (cause instanceof JsBayStatusError) {
        throw cause;
      }
      throw new Error(String(cause));
    }
  }
  retain(): Value {
    return invoke(() => Value.fromNative(native.retain(this.native())));
  }
  type(): ValueKind {
    return invoke(() => native.type(this.native()) as ValueKind);
  }
  toBool(): boolean {
    return invoke(() => native.toBool(this.native()) as boolean);
  }
  toNumber(): number {
    return invoke(() => native.toNumber(this.native()) as number);
  }
  /** UTF-8 bytes, including embedded NUL; decode deliberately at the application boundary. */
  toUtf8(): ArrayBuffer {
    return invoke(() => native.toUtf8(this.native()) as ArrayBuffer);
  }
  /** Decodes UTF-8 bytes, including embedded NUL, with the ArkTS system decoder. */
  string(): string {
    return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(this.toUtf8()), { stream: false });
  }
  toJson(): ArrayBuffer {
    return invoke(() => native.toJson(this.native()) as ArrayBuffer);
  }
  /** Returns a newly allocated copy of this JavaScript ArrayBuffer. */
  copyBuffer(): ArrayBuffer {
    return invoke(() => native.copyBuffer(this.native()) as ArrayBuffer);
  }
  /** Only meaningful for a Value returned from evaluate. */
  cacheHit(): boolean {
    return invoke(() => native.cacheHit(this.native()) as boolean);
  }
  get(key: string): Value {
    return invoke(() => Value.fromNative(native.get(this.native(), requireWellFormedText(key))));
  }
  set(key: string, value: Value): void {
    invoke((): void => {
      native.set(this.native(), requireWellFormedText(key), value.native());
    });
  }
  call(thisValue: Value, args: Value[] = []): Value {
    return invoke(() => Value.fromNative(native.call(this.native(), thisValue.native(), args.map((v: Value) => v.native()))));
  }
  construct(args: Value[] = []): Value {
    return invoke(() => Value.fromNative(native.construct(this.native(), args.map((v: Value) => v.native()))));
  }
  has(key: string): boolean {
    return invoke(() => native.has(this.native(), requireWellFormedText(key)) as boolean);
  }
  delete(key: string): boolean {
    return invoke(() => native.deleteKey(this.native(), requireWellFormedText(key)) as boolean);
  }
  keys(): Value {
    return invoke(() => Value.fromNative(native.keys(this.native())));
  }
  instanceOf(constructorValue: Value): boolean {
    return invoke(() => native.instanceOf(this.native(), constructorValue.native()) as boolean);
  }
}

export type HostCallback = (thisValue: Value, args: Value[]) => Value;
/** Runs synchronously on the Engine owner Worker. requestId is an opaque uint64 token for native completion. */
export type SyncStarter = (requestId: bigint, thisValue: Value, args: Value[]) => void;

/** A JavaScript throw. Close value after reading it. */
export class JsException extends Error {
  readonly value: Value;
  constructor(value: Value) {
    super('JavaScript exception');
    this.value = value;
  }
  /** Consumes the thrown value. A second JavaScript throw returns a fixed fallback. */
  describeAndClose(): string {
    this.value.requireOwnedForConsume();
    try {
      const description = this.value.string();
      this.value.close();

      return description;
    } catch (cause) {
      if (cause instanceof JsException) {
        try {
          cause.value.close();
        } finally {
          this.value.close();
        }

        return 'JavaScript exception';
      }
      if (cause instanceof JsBayStatusError) {
        throw new JsBayStatusError(cause.status, cause.code);
      }
      throw new Error(String(cause));
    }
  }
}

/* ArkTS permits Error subclasses in throw statements. This carries a native wrapped Value only across the synchronous N-API callback boundary. */
class NativeCallbackException extends Error {
  readonly value: NativeValue;
  constructor(value: NativeValue) {
    super('JavaScript exception');
    this.value = value;
  }
}

interface NativeThrown { value?: NativeValue }
interface NativeStatusThrown extends NativeThrown { status?: number; code?: string }
function invoke<T>(operation: () => T): T {
  try {
    return operation();
  } catch (cause) {
    const raw = (cause as NativeThrown).value;
    if (raw !== undefined) {
      throw new JsException(Value.fromNative(raw));
    }
    const nativeError = cause as NativeStatusThrown;
    if (nativeError.status !== undefined) {
      throw new JsBayStatusError(nativeError.status as JsBayStatus, nativeError.code);
    }
    throw new Error(String(cause));
  }
}

export interface ResourceLimits {
  maxTimers: number;
  maxTsfnHandles: number;
  maxPendingCalls: number;
  maxPendingBytes: number;
  maxPendingTasks: number;
}
export interface InstanceSnapshot {
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
export interface ResourceUsage {
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
export interface ResourceGlobalUsage {
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

/** Create, evaluate, access values, and close on one ArkTS Worker. The native bridge pins the owner to the creating thread and returns `JsBayStatus.WrongThread` for Engine/Value work elsewhere. Never transfer `Engine` or `Value` wrappers (or their N-API handles) to another Worker; multi-instance hosts use one Worker per instance id. The SDK returns queued loop work to the creating Worker automatically. */
/** Create, evaluate, access values, and close on one ArkTS Worker. The SDK returns queued work to that Worker automatically. Never transfer Engine or Value wrappers between Workers. */
export interface MemoryUsage {
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

export class Engine {
  private raw: NativeEngine;
  private instanceId: number;
  private closed: boolean = false;
  private loopTimer: number | undefined = undefined;
  private constructor(raw: NativeEngine, instanceId: number) {
    this.raw = raw;
    this.instanceId = instanceId;
    try {
      this.attachLoop();
    } catch (cause) {
      native.close(raw);
      this.closed = true;
      if (cause instanceof Error) {
        throw cause;
      }
      throw new Error(String(cause));
    }
  }
  private attachLoop(): void {
    native.attachLoop(this.raw, (delayMs: number, generation: bigint): void => {
      if (this.closed) {
        return;
      }
      // Always drop a previous timer first. delayMs < 0 is soft-cancel (suspend): clear only.
      this.clearLoopTimer();
      if (delayMs < 0) {
        return;
      }
      this.loopTimer = setTimeout((): void => {
        this.loopTimer = undefined;
        if (!this.closed) {
          native.runLoopTask(this.raw, generation);
        }
      }, delayMs);
    });
  }
  private clearLoopTimer(): void {
    if (this.loopTimer !== undefined) {
      clearTimeout(this.loopTimer);
    }
    this.loopTimer = undefined;
  }
  /** Constructs an Engine bound to the current ArkTS Worker thread. Call only on that Worker for the lifetime of the instance. Optional limits map to createWithLimits. */
  static create(instanceId: number, limits?: ResourceLimits): Engine {
    return invoke(() => {
      if (limits === undefined) {
        return new Engine(native.create(instanceId), instanceId);
      }
      return new Engine(native.createWithLimits(
        instanceId,
        limits.maxTimers,
        limits.maxTsfnHandles,
        limits.maxPendingCalls,
        limits.maxPendingBytes,
        limits.maxPendingTasks,
      ), instanceId);
    });
  }
  static globalResourceUsage(): ResourceGlobalUsage {
    return invoke(() => native.globalResourceUsage() as ResourceGlobalUsage);
  }
  evaluate(source: string, filename: string, cacheDir?: string, cacheVersion?: string): Value {
    const checkedSource = requireWellFormedText(source);
    const checkedFilename = requireWellFormedText(filename);
    if ((cacheDir === undefined) !== (cacheVersion === undefined)) {
      throw new JsBayStatusError(JsBayStatus.InvalidArgument);
    }
    const checkedCacheDir = cacheDir === undefined ? undefined : requireWellFormedText(cacheDir);
    const checkedCacheVersion = cacheVersion === undefined ? undefined : requireWellFormedText(cacheVersion);

    return invoke(() => Value.fromNative(checkedCacheDir !== undefined && checkedCacheVersion !== undefined
      ? native.evaluate(this.live(), checkedSource, checkedFilename, checkedCacheDir, checkedCacheVersion)
      : native.evaluate(this.live(), checkedSource, checkedFilename)));
  }
  global(): Value {
    return invoke(() => Value.fromNative(native.global(this.live())));
  }
  newString(value: string): Value {
    return invoke(() => Value.fromNative(native.newString(this.live(), requireWellFormedText(value))));
  }
  newNumber(value: number): Value {
    return invoke(() => Value.fromNative(native.newNumber(this.live(), value)));
  }
  newBool(value: boolean): Value {
    return invoke(() => Value.fromNative(native.newBool(this.live(), value)));
  }
  undefined(): Value {
    return invoke(() => Value.fromNative(native.undefined(this.live())));
  }
  'null'(): Value {
    return invoke(() => Value.fromNative(native.null(this.live())));
  }
  newJson(value: string): Value {
    return invoke(() => Value.fromNative(native.newJson(this.live(), requireWellFormedText(value))));
  }
  newError(message: string): Value {
    return invoke(() => Value.fromNative(native.newError(this.live(), requireWellFormedText(message))));
  }
  newObject(): Value {
    return invoke(() => Value.fromNative(native.newObject(this.live())));
  }
  newArray(): Value {
    return invoke(() => Value.fromNative(native.newArray(this.live())));
  }
  /** Copies the visible bytes of an ArrayBuffer, TypedArray, or DataView into JavaScript. */
  newArrayBuffer(value: BinarySource): Value {
    return invoke(() => Value.fromNative(native.newArrayBuffer(this.live(), value)));
  }
  bind(name: string, callback: HostCallback): Value {
    const checkedName = requireWellFormedText(name);
    const bridge = (thisValue: NativeValue, ...args: NativeValue[]): NativeValue => {
      try {
        return callback(Value.fromNative(thisValue, true), args.map((raw: NativeValue) => Value.fromNative(raw, true))).native();
      } catch (cause) {
        if (cause instanceof JsException) {
          throw new NativeCallbackException(cause.value.native());
        }
        throw new Error(String(cause));
      }
    };

    return invoke(() => Value.fromNative(native.bind(this.live(), checkedName, bridge)));
  }
  bindSync(name: string, timeoutMs: bigint, starter: SyncStarter): Value {
    const checkedName = requireWellFormedText(name);
    if (timeoutMs <= 0n) {
      throw new JsBayStatusError(JsBayStatus.InvalidArgument);
    }
    const bridge = (requestId: bigint, thisValue: NativeValue, args: NativeValue[]): void => {
      const values = args.map((raw: NativeValue) => Value.fromNative(raw, true));
      try {
        starter(requestId, Value.fromNative(thisValue, true), values);
      } catch (cause) {
        /* Data-only string exception so the blocked JavaScript call does not wait for a timeout. */
        native.completeSync(requestId, JsBayStatus.Exception, 0, String(cause));
      }
    };

    return invoke(() => Value.fromNative(native.bindSync(this.live(), checkedName, timeoutMs, bridge)));
  }
  /** Completes with a UTF-8 string. Prefer native `jsbay_sync_complete` from a background thread to avoid N-API on the hot path. */
  static completeSyncString(requestId: bigint, value: string): JsBayStatus {
    return Engine.completeSync(requestId, JsBayStatus.Ok, 0, value);
  }
  /** Completes with opaque octets via ArrayBuffer/TypedArray/DataView. Prefer native C for hot paths. */
  static completeSyncBytes(requestId: bigint, value: BinarySource): JsBayStatus {
    return Engine.completeSync(requestId, JsBayStatus.Ok, 1, value);
  }
  static rejectSync(requestId: bigint, message: string): JsBayStatus {
    return Engine.completeSync(requestId, JsBayStatus.Exception, 0, message);
  }
  /** Low-level typed completion. kind: 0=UTF8_STRING, 1=BYTES, 2=JSON (explicit opt-in). No Engine argument; safe from another Worker env.
   * For kind=BYTES + OK, pass ArrayBuffer/TypedArray/DataView (no UTF-8 check). STRING/JSON/EXCEPTION still require well-formed text. */
  static completeSync(requestId: bigint, outcome: JsBayStatus.Ok | JsBayStatus.Exception, kind: number, data: string | BinarySource): JsBayStatus {
    if (outcome !== JsBayStatus.Ok && outcome !== JsBayStatus.Exception) {
      return JsBayStatus.InvalidArgument;
    }
    if (kind !== 0 && kind !== 1 && kind !== 2) {
      return JsBayStatus.InvalidArgument;
    }
    if (kind === 1 && outcome === JsBayStatus.Ok) {
      return native.completeSync(requestId, outcome, kind, data) as JsBayStatus;
    }
    if (typeof data !== 'string') {
      return JsBayStatus.InvalidArgument;
    }
    const checked = requireWellFormedText(data);
    return native.completeSync(requestId, outcome, kind, checked) as JsBayStatus;
  }
  runLoop(): void {
    invoke((): void => {
      native.runLoop(this.live());
    });
    this.clearLoopTimer();
    if (!this.closed) {
      this.attachLoop();
    }
  }
  stopLoop(): boolean {
    return this.closed ? false : native.stopLoop(this.raw);
  }
  /** Future timer/task admissions only. Pair Hide→BACKGROUND (1) and Show→FOREGROUND (0) with suspend/resume. */
  setAdmissionClass(cls: number): boolean {
    if (this.closed) {
      return false;
    }
    if (cls !== 0 && cls !== 1) {
      return false;
    }
    return native.setAdmissionClass(this.raw, cls) as boolean;
  }
  getAdmissionClass(): number {
    return this.closed ? -1 : native.getAdmissionClass(this.raw) as number;
  }
  snapshot(): InstanceSnapshot | null {
    if (this.closed) {
      return null;
    }
    return native.snapshotEngine(this.instanceId) as InstanceSnapshot | null;
  }
  static listEngines(): number[] {
    return native.listEngines() as number[];
  }
  static snapshot(id: number): InstanceSnapshot | null {
    return native.snapshotEngine(id) as InstanceSnapshot | null;
  }
  /** Keep-alive pause for Hide. Does not detach or clear JS VM timers; clears the platform setTimeout only. */
  suspendLoop(): boolean {
    if (this.closed) {
      return false;
    }
    this.clearLoopTimer();
    return native.suspendLoop(this.raw);
  }
  /** Resume after suspendLoop. Does not recreate the engine. */
  resumeLoop(): boolean {
    return this.closed ? false : native.resumeLoop(this.raw);
  }
  isSuspended(): boolean {
    return this.closed ? false : native.isSuspended(this.raw);
  }
  requestInterrupt(): boolean {
    return this.closed ? false : native.requestInterrupt(this.raw) as boolean;
  }
  clearInterrupt(): boolean {
    return invoke(() => native.clearInterrupt(this.live()) as boolean);
  }
  setExecutionTimeLimit(milliseconds: bigint): boolean {
    return invoke(() => native.setExecutionTimeLimit(this.live(), milliseconds) as boolean);
  }
  setMemoryLimit(bytes: bigint): boolean {
    return invoke(() => native.setMemoryLimit(this.live(), bytes) as boolean);
  }
  setResourceLimits(limits: ResourceLimits): boolean {
    return invoke(() => native.setResourceLimits(
      this.live(),
      limits.maxTimers,
      limits.maxTsfnHandles,
      limits.maxPendingCalls,
      limits.maxPendingBytes,
      limits.maxPendingTasks,
    ) as boolean);
  }
  resourceUsage(): ResourceUsage {
    return invoke(() => native.resourceUsage(this.live()) as ResourceUsage);
  }
  getMemoryUsage(): MemoryUsage {
    return invoke(() => native.getMemoryUsage(this.live()) as MemoryUsage);
  }
  runGc(): boolean {
    return invoke(() => native.runGc(this.live()) as boolean);
  }
  /** Returns the selected port, or 0 if this platform has no inspector. */
  inspectorStart(port: number): number {
    return invoke(() => native.inspectorStart(this.live(), port) as number);
  }
  inspectorStop(): void {
    invoke((): void => {
      native.inspectorStop(this.live());
    });
  }
  close(): void {
    if (!this.closed) {
      invoke((): void => {
        this.clearLoopTimer();
        native.close(this.raw);
        this.closed = true;
      });
    }
  }
  private live(): NativeEngine {
    if (this.closed) {
      throw new JsBayStatusError(JsBayStatus.InstanceNotFound);
    }

    return this.raw;
  }
}
