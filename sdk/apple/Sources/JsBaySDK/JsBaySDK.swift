import CoreFoundation
import Darwin
import Foundation
import JsBay

/// Public numeric status values matching `jsbay_status_t`.
public enum JsBayStatus {
  public static let ok = Int32(JSBAY_OK.rawValue)
  public static let exception = Int32(JSBAY_EXCEPTION.rawValue)
  public static let invalidArgument = Int32(JSBAY_INVALID_ARGUMENT.rawValue)
  public static let wrongThread = Int32(JSBAY_WRONG_THREAD.rawValue)
  public static let instanceNotFound = Int32(JSBAY_INSTANCE_NOT_FOUND.rawValue)
  public static let staleValue = Int32(JSBAY_STALE_VALUE.rawValue)
  public static let outOfMemory = Int32(JSBAY_OUT_OF_MEMORY.rawValue)
  public static let unsupported = Int32(JSBAY_UNSUPPORTED.rawValue)
  public static let loopFailed = Int32(JSBAY_LOOP_FAILED.rawValue)
}

public enum JsBayError: Error, Equatable, CustomStringConvertible {
  case status(Int32)
  case engineClosed
  case wrongThread
  case invalidValue

  public var description: String {
    switch self {
    case .status(let raw): return "JsBay status \(raw)"
    case .engineClosed: return "JsBay engine is closed"
    case .wrongThread: return "JsBay must be called on its owner thread"
    case .invalidValue: return "JsBay value is closed or borrowed"
    }
  }

  /// Stable `jsbay_status_t` equivalent for both C failures and SDK precondition failures. Callers must not infer a status from enum order.
  public var statusCode: Int32 {
    switch self {
    case .status(let raw): return raw
    case .engineClosed: return JsBayStatus.instanceNotFound
    case .wrongThread: return JsBayStatus.wrongThread
    case .invalidValue: return JsBayStatus.staleValue
    }
  }
}

public final class JsException: Error {
  public let value: Value
  fileprivate init(_ value: Value) { self.value = value }

  /// Returns the thrown value's text and closes it. A second JavaScript throw closes both values and returns a fixed fallback.
  public func describeAndClose() throws -> String {
    try value.requireOwnedForConsume()
    do {
      let description = try value.string()
      try value.close()
      return description
    } catch let secondary as JsException {
      defer { try? value.close() }
      try secondary.value.close()
      return "JavaScript exception"
    }
  }
}

/// A thread-safe, data-only completion for `Engine.bindSync`. It may run on a background queue and never calls Engine or Value APIs. Prefer calling `jsbay_sync_complete` from native code on the hot path.
public final class SyncCompletion: @unchecked Sendable {
  private let requestID: UInt64
  private let lock = NSLock()
  private var terminal = false
  fileprivate init(_ requestID: UInt64) { self.requestID = requestID }
  @discardableResult public func tryResolveString(_ value: String) -> Int32 {
    complete(JSBAY_OK, JSBAY_SYNC_PAYLOAD_UTF8_STRING, Array(value.utf8))
  }
  @discardableResult public func tryResolveBytes(_ bytes: [UInt8]) -> Int32 {
    complete(JSBAY_OK, JSBAY_SYNC_PAYLOAD_BYTES, bytes)
  }
  @discardableResult public func tryReject(_ message: String) -> Int32 {
    complete(JSBAY_EXCEPTION, JSBAY_SYNC_PAYLOAD_UTF8_STRING, Array(message.utf8))
  }
  public func resolveString(_ value: String) throws {
    let status = tryResolveString(value)
    if status != JsBayStatus.ok { throw JsBayError.status(status) }
  }
  public func resolveBytes(_ bytes: [UInt8]) throws {
    let status = tryResolveBytes(bytes)
    if status != JsBayStatus.ok { throw JsBayError.status(status) }
  }
  public func reject(_ message: String) throws {
    let status = tryReject(message)
    if status != JsBayStatus.ok { throw JsBayError.status(status) }
  }
  private func complete(_ outcome: jsbay_status_t, _ kind: jsbay_sync_payload_kind_t, _ bytes: [UInt8]) -> Int32 {
    lock.lock()
    defer { lock.unlock() }
    if terminal { return JsBayStatus.staleValue }
    let status: jsbay_status_t = bytes.withUnsafeBufferPointer {
      jsbay_sync_complete(requestID, outcome, kind, jsbay_utf8_t(data: $0.baseAddress, len: $0.count))
    }
    let raw = Int32(status.rawValue)
    if raw == JsBayStatus.ok || raw == JsBayStatus.staleValue { terminal = true }
    return raw
  }
}

public enum ValueKind: Equatable {
  case undefined, null, bool, number, string, object, array, function, symbol, bigInt
}

public final class Value {
  fileprivate enum Ownership { case owned, borrowed, expiredBorrowed, closed }
  fileprivate weak var engine: Engine?
  fileprivate var handle: UInt64
  fileprivate var ownership: Ownership

  fileprivate init(engine: Engine, handle: UInt64, ownership: Ownership = .owned) {
    self.engine = engine
    self.handle = handle
    self.ownership = ownership
  }

  deinit {
    // ARC may release on a non-owner thread. Explicit close() is required.
  }

  public func close() throws {
    switch ownership {
    case .closed:
      return
    case .borrowed:
      // Borrowed callback parameters do not own a C reference. Keep the wrapper valid until scope exit, where it becomes stale.
      throw JsBayError.status(JsBayStatus.invalidArgument)
    case .expiredBorrowed:
      throw JsBayError.status(JsBayStatus.staleValue)
    case .owned:
      break
    }
    guard let engine, engine.isOpen else {
      ownership = .closed
      handle = 0
      return
    }
    try engine.requireOwner()
    let status = jsbay_value_release(handle)
    try engine.requireOK(status)
    ownership = .closed
    handle = 0
  }

  public func retain() throws -> Value {
    let engine = try usableEngine()
    var duplicate: UInt64 = 0
    try engine.requireOK(jsbay_value_retain(handle, &duplicate))
    return Value(engine: engine, handle: duplicate)
  }

  public func kind() throws -> ValueKind {
    let engine = try usableEngine()
    var raw = JSBAY_VALUE_UNDEFINED
    try engine.requireOK(jsbay_value_type(handle, &raw))
    switch raw.rawValue {
    case JSBAY_VALUE_UNDEFINED.rawValue: return .undefined
    case JSBAY_VALUE_NULL.rawValue: return .null
    case JSBAY_VALUE_BOOL.rawValue: return .bool
    case JSBAY_VALUE_NUMBER.rawValue: return .number
    case JSBAY_VALUE_STRING.rawValue: return .string
    case JSBAY_VALUE_OBJECT.rawValue: return .object
    case JSBAY_VALUE_ARRAY.rawValue: return .array
    case JSBAY_VALUE_FUNCTION.rawValue: return .function
    case JSBAY_VALUE_SYMBOL.rawValue: return .symbol
    case JSBAY_VALUE_BIGINT.rawValue: return .bigInt
    default: throw JsBayError.status(-1)
    }
  }

  /// The JavaScript type classification. `kind()` remains as a readable alias.
  public func type() throws -> ValueKind { try kind() }

  public func bool() throws -> Bool {
    let engine = try usableEngine()
    var output = false
    try engine.requireOK(jsbay_value_to_bool(handle, &output))
    return output
  }

  public func number() throws -> Double {
    let engine = try usableEngine()
    var output = 0.0
    try engine.requireOK(jsbay_value_to_number(handle, &output))
    return output
  }

  public func string() throws -> String { try bytes(jsbay_value_to_utf8) }
  public func json() throws -> String { try bytes(jsbay_value_to_json) }
  public func bytes() throws -> Data {
    let engine = try usableEngine()
    var output = jsbay_bytes_t(data: nil, len: 0)
    var exception: UInt64 = 0
    let status = jsbay_value_copy_buffer(handle, &output, &exception)
    try engine.voidResult(status, exception)
    defer { if output.data != nil { jsbay_free_bytes(output) } }
    if output.len == 0 { return Data() }
    guard let data = output.data else { throw JsBayError.status(-1) }
    return Data(bytes: data, count: output.len)
  }

  public func get(_ key: String) throws -> Value {
    let engine = try usableEngine()
    return try engine.withUTF8(key) { key in
      var value: UInt64 = 0
      var exception: UInt64 = 0
      let status = jsbay_value_get(handle, key, &value, &exception)
      return try engine.valueResult(status, value, exception)
    }
  }

  public func set(_ key: String, to value: Value) throws {
    let engine = try usableEngine()
    try engine.requireSame(value)
    try engine.withUTF8(key) { key in
      var exception: UInt64 = 0
      let status = jsbay_value_set(handle, key, value.handle, &exception)
      try engine.voidResult(status, exception)
    }
  }

  public func call(this thisValue: Value? = nil, arguments: [Value] = []) throws -> Value {
    let engine = try usableEngine()
    let receiver: Value
    var temporaryReceiver: Value?
    if let thisValue {
      receiver = thisValue
    } else {
      let undefined = try engine.undefined()
      temporaryReceiver = undefined
      receiver = undefined
    }
    defer { try? temporaryReceiver?.close() }
    try engine.requireSame(receiver)
    for argument in arguments { try engine.requireSame(argument) }
    let handles = arguments.map(\.handle)
    var result: UInt64 = 0
    var exception: UInt64 = 0
    let status = handles.withUnsafeBufferPointer {
      jsbay_value_call(handle, receiver.handle, $0.baseAddress, $0.count, &result, &exception)
    }
    return try engine.valueResult(status, result, exception)
  }

  public func construct(arguments: [Value] = []) throws -> Value {
    let engine = try usableEngine()
    for argument in arguments { try engine.requireSame(argument) }
    let handles = arguments.map(\.handle)
    var result: UInt64 = 0
    var exception: UInt64 = 0
    let status = handles.withUnsafeBufferPointer {
      jsbay_value_construct(handle, $0.baseAddress, $0.count, &result, &exception)
    }
    return try engine.valueResult(status, result, exception)
  }

  public func has(_ key: String) throws -> Bool {
    let engine = try usableEngine()
    return try engine.withUTF8(key) { key in
      var found = false
      var exception: UInt64 = 0
      let status = jsbay_value_has(handle, key, &found, &exception)
      try engine.voidResult(status, exception)
      return found
    }
  }

  public func delete(_ key: String) throws -> Bool {
    let engine = try usableEngine()
    return try engine.withUTF8(key) { key in
      var deleted = false
      var exception: UInt64 = 0
      let status = jsbay_value_delete(handle, key, &deleted, &exception)
      try engine.voidResult(status, exception)
      return deleted
    }
  }

  public func keys() throws -> Value {
    let engine = try usableEngine()
    var array: UInt64 = 0
    var exception: UInt64 = 0
    let status = jsbay_value_keys(handle, &array, &exception)
    return try engine.valueResult(status, array, exception)
  }

  public func instanceOf(_ constructor: Value) throws -> Bool {
    let engine = try usableEngine()
    try engine.requireSame(constructor)
    var result = false
    var exception: UInt64 = 0
    let status = jsbay_value_instance_of(handle, constructor.handle, &result, &exception)
    try engine.voidResult(status, exception)
    return result
  }

  fileprivate func callbackHandle(for callbackEngine: Engine) throws -> UInt64 {
    try callbackEngine.requireSame(self)
    var duplicate: UInt64 = 0
    try callbackEngine.requireOK(jsbay_value_retain(handle, &duplicate))
    return duplicate
  }

  fileprivate func closeFromCallbackScope() {
    guard ownership == .owned else { return }
    guard let engine, engine.isOpen else {
      ownership = .closed
      handle = 0
      return
    }
    // Callback scopes run on the engine owner thread. A close request made in the callback marks the engine closed; then C must not be touched.
    _ = jsbay_value_release(handle)
    ownership = .closed
    handle = 0
  }

  fileprivate func invalidateBorrowed() {
    guard ownership == .borrowed else { return }
    ownership = .expiredBorrowed
    handle = 0
  }

  private func bytes(
    _ function: (UInt64, UnsafeMutablePointer<jsbay_bytes_t>?, UnsafeMutablePointer<UInt64>?) ->
      jsbay_status_t
  ) throws -> String {
    let engine = try usableEngine()
    var output = jsbay_bytes_t(data: nil, len: 0)
    var exception: UInt64 = 0
    let status = function(handle, &output, &exception)
    defer { if output.data != nil { jsbay_free_bytes(output) } }
    try engine.voidResult(status, exception)
    return String(
      decoding: UnsafeBufferPointer(start: output.data, count: output.len), as: UTF8.self)
  }

  fileprivate func usableEngine() throws -> Engine {
    switch ownership {
    case .owned, .borrowed:
      break
    case .expiredBorrowed:
      throw JsBayError.status(JsBayStatus.staleValue)
    case .closed:
      throw JsBayError.invalidValue
    }
    guard handle != 0 else { throw JsBayError.invalidValue }
    guard let engine, engine.isOpen else { throw JsBayError.invalidValue }
    try engine.requireOwner()
    return engine
  }

  fileprivate func requireOwnedForConsume() throws {
    switch ownership {
    case .owned:
      break
    case .borrowed:
      throw JsBayError.status(JsBayStatus.invalidArgument)
    case .expiredBorrowed, .closed:
      throw JsBayError.status(JsBayStatus.staleValue)
    }
    guard handle != 0, let engine else { throw JsBayError.status(JsBayStatus.staleValue) }
    try engine.requireOpen()
  }
}

public struct ResourceLimits: Equatable, Sendable {
  public var maxTimers: Int
  public var maxTsfnHandles: Int
  public var maxPendingCalls: Int
  public var maxPendingBytes: Int
  public var maxPendingTasks: Int

  public init(
    maxTimers: Int = 4096,
    maxTsfnHandles: Int = 256,
    maxPendingCalls: Int = 4096,
    maxPendingBytes: Int = 8 * 1024 * 1024,
    maxPendingTasks: Int = 4096
  ) {
    self.maxTimers = maxTimers
    self.maxTsfnHandles = maxTsfnHandles
    self.maxPendingCalls = maxPendingCalls
    self.maxPendingBytes = maxPendingBytes
    self.maxPendingTasks = maxPendingTasks
  }

  fileprivate func withCLimits<R>(_ body: (UnsafePointer<jsbay_resource_limits_t>) throws -> R) throws -> R {
    guard maxTimers >= 0, maxTsfnHandles >= 0, maxPendingCalls >= 0, maxPendingBytes >= 0, maxPendingTasks >= 0 else {
      throw JsBayError.status(JsBayStatus.invalidArgument)
    }
    var limits = jsbay_resource_limits_t(
      struct_size: UInt32(MemoryLayout<jsbay_resource_limits_t>.size),
      max_timers: maxTimers,
      max_tsfn_handles: maxTsfnHandles,
      max_pending_calls: maxPendingCalls,
      max_pending_bytes: maxPendingBytes,
      max_pending_tasks: maxPendingTasks
    )
    return try withUnsafePointer(to: &limits, body)
  }
}

public struct ResourceUsage: Equatable, Sendable {
  public var timers: Int
  public var tsfnHandles: Int
  public var pendingCalls: Int
  public var nativeTasks: Int
  public var scriptTasks: Int
  public var pendingBytes: Int
  public var limits: ResourceLimits
}

public struct InstanceSnapshot: Equatable, Sendable {
  public var instanceId: Int32
  public var generation: UInt64
  public var ownerThreadId: UInt64
  public var loopMode: UInt8
  public var flags: UInt8
  public var admissionClassRaw: Int
  public var timersReserved: Int
  public var timersRegistered: Int
  public var scriptTasksQueued: Int
  public var nativeTasksQueued: Int
  public var pendingBytes: Int
  public var maxTimers: Int
  public var maxPendingTasks: Int
  public var maxPendingBytes: Int
}

public struct ResourceGlobalUsage: Equatable, Sendable {
  public var timers: Int
  public var tsfnHandles: Int
  public var pendingCalls: Int
  public var nativeTasks: Int
  public var scriptTasks: Int
  public var pendingBytes: Int
  public var maxTimers: Int
  public var maxTsfnHandles: Int
  public var maxPendingCalls: Int
  public var maxNativeTasks: Int
  public var maxScriptTasks: Int
  public var maxPendingBytes: Int
  public var fgHeadroomTimers: Int
  public var fgHeadroomTsfnHandles: Int
  public var fgHeadroomPendingCalls: Int
  public var fgHeadroomNativeTasks: Int
  public var fgHeadroomScriptTasks: Int
  public var fgHeadroomPendingBytes: Int
  public var bgEffectiveMaxTimers: Int
  public var bgEffectiveMaxTsfnHandles: Int
  public var bgEffectiveMaxPendingCalls: Int
  public var bgEffectiveMaxNativeTasks: Int
  public var bgEffectiveMaxScriptTasks: Int
  public var bgEffectiveMaxPendingBytes: Int
}

public final class Engine {
  public enum Primitive {
    case undefined, null
    case bool(Bool)
    case number(Double)
    case string(String)
  }
  public final class CacheOptions {
    public let directory: String
    public let version: String
    public fileprivate(set) var didHit = false
    public init(directory: String, version: String) {
      self.directory = directory
      self.version = version
    }
  }

  public typealias NativeCallback = (Value, [Value]) throws -> Value
  public typealias SyncStarter = (Value, [Value], SyncCompletion) -> Void
  fileprivate final class Binding {
    let callback: NativeCallback
    init(_ callback: @escaping NativeCallback) { self.callback = callback }
  }
  fileprivate final class SyncBinding {
    let starter: SyncStarter
    init(_ starter: @escaping SyncStarter) { self.starter = starter }
  }
  fileprivate final class LoopBinding {
    private let lock = NSLock()
    private let runLoop: CFRunLoop
    private var attached = true
    private var generation: UInt64 = 0
    private var timer: CFRunLoopTimer?
    private let id: Int32

    init(_ runLoop: CFRunLoop, id: Int32) {
      self.runLoop = runLoop
      self.id = id
    }

    func schedule(
      _ delay: UInt64, _ task: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void,
      _ data: UnsafeMutableRawPointer?
    ) -> Bool {
      lock.lock()
      guard attached else {
        lock.unlock()
        return false
      }
      generation &+= 1
      let ticket = generation
      lock.unlock()
      CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
        lock.lock()
        guard attached, generation == ticket else {
          lock.unlock()
          return
        }
        if let timer { CFRunLoopTimerInvalidate(timer) }
        let fireAt = CFAbsoluteTimeGetCurrent() + Double(delay) / 1_000
        timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, fireAt, 0, 0, 0) {
          [weak self] _ in
          guard let self else { return }
          self.lock.lock()
          let run = self.attached && self.generation == ticket
          self.timer = nil
          self.lock.unlock()
          if run {
            task(data)
            _ = jsbay_engine_loop_status(self.id)
          }
        }
        CFRunLoopAddTimer(runLoop, timer!, .commonModes)
        lock.unlock()
      }
      CFRunLoopWakeUp(runLoop)
      return true
    }

    /// Soft cancel: drop the pending timer only. Binding stays reusable for suspend/resume.
    func cancel() {
      lock.lock()
      generation &+= 1
      if let timer { CFRunLoopTimerInvalidate(timer) }
      timer = nil
      lock.unlock()
    }

    /// Hard teardown used only when releasing the binding after detach/destroy.
    func shutdown() {
      lock.lock()
      attached = false
      generation &+= 1
      if let timer { CFRunLoopTimerInvalidate(timer) }
      timer = nil
      lock.unlock()
    }
  }

  public let id: Int32
  private let owner: pthread_t
  private let allowMainRunLoopAttach: Bool
  private var callbackScopes: [CallbackScope] = []
  private var loopBinding: UnsafeMutableRawPointer?
  private var loopRestoreFailure: Int32?
  fileprivate private(set) var isOpen = true

  public convenience init(id: Int32) throws {
    try self.init(id: id, limits: nil, allowMainRunLoopAttach: false)
  }

  public convenience init(id: Int32, limits: ResourceLimits?) throws {
    try self.init(id: id, limits: limits, allowMainRunLoopAttach: false)
  }

  /// Creates an engine on the calling thread and attaches the automatic CFRunLoop driver.
  ///
  /// Attaching to the process main run loop schedules JavaScript on the UI/main thread. Multi-instance hosts should create one engine per dedicated owner thread instead. Pass `allowMainRunLoopAttach: true` only when intentionally attaching there.
  public convenience init(id: Int32, allowMainRunLoopAttach: Bool) throws {
    try self.init(id: id, limits: nil, allowMainRunLoopAttach: allowMainRunLoopAttach)
  }

  public init(id: Int32, limits: ResourceLimits?, allowMainRunLoopAttach: Bool = false) throws {
    self.id = id
    self.owner = pthread_self()
    self.allowMainRunLoopAttach = allowMainRunLoopAttach
    if Engine.isCurrentMainRunLoop() && !allowMainRunLoopAttach {
      throw JsBayError.status(JsBayStatus.invalidArgument)
    }
    let created: Bool
    if let limits {
      created = try limits.withCLimits { jsbay_engine_create_with_limits(id, nil, nil, $0) }
    } else {
      created = jsbay_engine_create(id, nil, nil)
    }
    guard created else {
      throw JsBayError.status(JsBayStatus.invalidArgument)
    }
    let binding = LoopBinding(CFRunLoopGetCurrent(), id: id)
    let pointer = Unmanaged.passRetained(binding).toOpaque()
    let status = jsbay_engine_attach_loop(
      id, jsbaySwiftLoopSchedule, jsbaySwiftLoopCancel, pointer)
    guard status.rawValue == JSBAY_OK.rawValue else {
      Unmanaged<LoopBinding>.fromOpaque(pointer).release()
      jsbay_engine_destroy(id)
      throw JsBayError.status(Int32(status.rawValue))
    }
    loopBinding = pointer
    Engine.liveLock.lock()
    Engine.live[id] = WeakBox(self)
    Engine.liveLock.unlock()
  }

  deinit {
    // Explicit close() is required; no C calls from deinit.
  }

  public func close() throws {
    try requireOwner()
    Engine.liveLock.lock()
    guard isOpen else {
      Engine.liveLock.unlock()
      return
    }
    Engine.liveLock.unlock()
    try requireOK(jsbay_engine_detach_loop(id))
    Engine.liveLock.lock()
    guard isOpen else {
      Engine.liveLock.unlock()
      return
    }
    if let loopBinding {
      Unmanaged<LoopBinding>.fromOpaque(loopBinding).takeUnretainedValue().shutdown()
      Unmanaged<LoopBinding>.fromOpaque(loopBinding).release()
      self.loopBinding = nil
    }
    isOpen = false
    Engine.live.removeValue(forKey: id)
    Engine.liveLock.unlock()
    jsbay_engine_destroy(id)
  }

  public func evaluate(_ source: String, filename: String = "<eval>", cache: CacheOptions? = nil)
    throws -> Value
  {
    try requireOpen()
    return try withUTF8(source) { source in
      try withUTF8(filename) { filename in
        var value: UInt64 = 0
        var exception: UInt64 = 0
        if let cache {
          return try withUTF8(cache.directory) { dir in
            try withUTF8(cache.version) { version in
              cache.didHit = false
              return try withUnsafeMutablePointer(to: &cache.didHit) { hit in
                var options = jsbay_engine_evaluate_options_t(
                  struct_size: UInt32(MemoryLayout<jsbay_engine_evaluate_options_t>.size),
                  cache_dir: dir, cache_version: version, out_cache_hit: hit)
                let status = jsbay_engine_evaluate(
                  id, source, filename, &options, &value, &exception)
                return try valueResult(status, value, exception)
              }
            }
          }
        }
        let status = jsbay_engine_evaluate(id, source, filename, nil, &value, &exception)
        return try valueResult(status, value, exception)
      }
    }
  }

  public func global() throws -> Value { try simpleValue { jsbay_engine_global(id, $0) } }
  public func undefined() throws -> Value { try simpleValue { jsbay_value_undefined(id, $0) } }
  public func null() throws -> Value { try simpleValue { jsbay_value_null(id, $0) } }
  public func bool(_ input: Bool) throws -> Value {
    try simpleValue { jsbay_value_new_bool(id, input, $0) }
  }
  public func number(_ input: Double) throws -> Value {
    try simpleValue { jsbay_value_new_number(id, input, $0) }
  }
  public func string(_ input: String) throws -> Value {
    try withUTF8(input) { text in try simpleValue { jsbay_value_new_string(id, text, $0) } }
  }
  public func arrayBuffer(_ input: Data) throws -> Value {
    try simpleValue { out in
      input.withUnsafeBytes { bytes in
        jsbay_value_new_array_buffer(
          id, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, out)
      }
    }
  }
  public func object() throws -> Value { try simpleValue { jsbay_value_new_object(id, $0) } }
  public func array() throws -> Value { try simpleValue { jsbay_value_new_array(id, $0) } }
  public func error(_ message: String) throws -> Value {
    try withUTF8(message) { text in try simpleValue { jsbay_value_new_error(id, text, $0) } }
  }

  /// Creates a JavaScript primitive with one stable entry point for wrappers.
  public func newPrimitive(_ primitive: Primitive) throws -> Value {
    switch primitive {
    case .undefined: return try undefined()
    case .null: return try null()
    case .bool(let input): return try bool(input)
    case .number(let input): return try number(input)
    case .string(let input): return try string(input)
    }
  }

  public func json(_ text: String) throws -> Value {
    try requireOpen()
    return try withUTF8(text) { text in
      var value: UInt64 = 0
      var exception: UInt64 = 0
      return try valueResult(jsbay_value_new_json(id, text, &value, &exception), value, exception)
    }
  }

  public func bind(_ name: String, _ callback: @escaping NativeCallback) throws -> Value {
    try requireOpen()
    let pointer = Unmanaged.passRetained(Binding(callback)).toOpaque()
    var function: UInt64 = 0
    var exception: UInt64 = 0
    do {
      let value = try withUTF8(name) { name -> Value in
        let status = jsbay_engine_bind(
          id, name, jsbaySwiftCallback, pointer, jsbaySwiftFinalize, &function, &exception)
        return try valueResult(status, function, exception)
      }
      return value
    } catch {
      Unmanaged<Binding>.fromOpaque(pointer).release()
      throw error
    }
  }

  public func bindSync(
    _ name: String, timeoutMilliseconds: UInt64, _ starter: @escaping SyncStarter
  ) throws -> Value {
    try requireOpen()
    guard timeoutMilliseconds > 0 else { throw JsBayError.status(JsBayStatus.invalidArgument) }
    let pointer = Unmanaged.passRetained(SyncBinding(starter)).toOpaque()
    var function: UInt64 = 0
    var exception: UInt64 = 0
    do {
      return try withUTF8(name) { name in
        try valueResult(
          jsbay_engine_bind_sync(
            id, name, jsbaySwiftSyncStart, pointer, jsbaySwiftSyncFinalize, timeoutMilliseconds,
            &function, &exception), function, exception)
      }
    } catch {
      Unmanaged<SyncBinding>.fromOpaque(pointer).release()
      throw error
    }
  }

  /// Builds an exception that preserves the exact JavaScript value to throw.
  public func exception(_ value: Value) throws -> JsException {
    try requireSame(value)
    return JsException(value)
  }

  /// Blocks the owner thread on the core loop. Refuses the process main thread unless this engine was created with `allowMainRunLoopAttach: true`.
  public func runLoop() throws {
    try requireOpen()
    if Engine.isMainThread() && !allowMainRunLoopAttach {
      throw JsBayError.status(JsBayStatus.invalidArgument)
    }
    try requireOK(jsbay_engine_detach_loop(id))
    let runStatus = jsbay_engine_run_loop(id)
    guard runStatus.rawValue == JSBAY_OK.rawValue else {
      let restoreStatus = restoreAutomaticLoop()
      if restoreStatus.rawValue != JSBAY_OK.rawValue, isOpen {
        loopRestoreFailure = Int32(restoreStatus.rawValue)
      }
      throw JsBayError.status(Int32(runStatus.rawValue))
    }
    guard isOpen else { return }
    let restoreStatus = restoreAutomaticLoop()
    guard restoreStatus.rawValue == JSBAY_OK.rawValue else {
      loopRestoreFailure = Int32(restoreStatus.rawValue)
      throw JsBayError.status(Int32(restoreStatus.rawValue))
    }
  }

  private func restoreAutomaticLoop() -> jsbay_status_t {
    Engine.liveLock.lock()
    defer { Engine.liveLock.unlock() }
    guard isOpen, Engine.live[id]?.value === self else { return JSBAY_INSTANCE_NOT_FOUND }
    let binding = LoopBinding(CFRunLoopGetCurrent(), id: id)
    let pointer = Unmanaged.passRetained(binding).toOpaque()
    let status = jsbay_engine_attach_loop(
      id, jsbaySwiftLoopSchedule, jsbaySwiftLoopCancel, pointer)
    guard status.rawValue == JSBAY_OK.rawValue else {
      Unmanaged<LoopBinding>.fromOpaque(pointer).release()
      return status
    }
    if let previous = loopBinding {
      Unmanaged<LoopBinding>.fromOpaque(previous).takeUnretainedValue().shutdown()
      Unmanaged<LoopBinding>.fromOpaque(previous).release()
    }
    loopBinding = pointer
    loopRestoreFailure = nil
    return status
  }
  public func stopLoop() -> Bool {
    Engine.liveLock.lock()
    defer { Engine.liveLock.unlock() }
    guard isOpen, Engine.live[id]?.value === self else { return false }
    return jsbay_engine_stop_loop(id)
  }
  /// Keep-alive pause for multi-runtime Hide. Cancels pending platform schedules without detaching or clearing timers/VM state.
  public func suspendLoop() -> Bool {
    Engine.liveLock.lock()
    defer { Engine.liveLock.unlock() }
    guard isOpen, Engine.live[id]?.value === self else { return false }
    return jsbay_engine_suspend(id)
  }
  /// Resume after `suspendLoop`. Does not recreate the engine.
  public func resumeLoop() -> Bool {
    Engine.liveLock.lock()
    defer { Engine.liveLock.unlock() }
    guard isOpen, Engine.live[id]?.value === self else { return false }
    return jsbay_engine_resume(id)
  }
  public enum AdmissionClass: Int {
    case foreground = 0
    case background = 1
  }

  /// Future admissions only. Pair Hide→background and Show→foreground with suspend/resume.

  public static func listEngines() -> [Int32] {
    let total = jsbay_engine_list(nil, 0)
    guard total > 0 else { return [] }
    var ids = [Int32](repeating: 0, count: Int(total))
    let written = ids.withUnsafeMutableBufferPointer { buf in
      jsbay_engine_list(buf.baseAddress, buf.count)
    }
    if written < total {
      // Raced with destroy; truncate to what we received on the second pass.
      return Array(ids.prefix(Int(written)))
    }
    return ids
  }

  public static func snapshot(identifier: Int32) -> InstanceSnapshot? {
    var snap = jsbay_instance_snapshot_t()
    snap.struct_size = UInt32(MemoryLayout<jsbay_instance_snapshot_t>.size)
    guard jsbay_engine_snapshot(identifier, &snap) else { return nil }
    return InstanceSnapshot(
      instanceId: snap.instance_id,
      generation: snap.generation,
      ownerThreadId: snap.owner_thread_id,
      loopMode: snap.loop_mode,
      flags: snap.flags,
      admissionClassRaw: Int(snap.admission_class.rawValue),
      timersReserved: Int(snap.timers_reserved),
      timersRegistered: Int(snap.timers_registered),
      scriptTasksQueued: Int(snap.script_tasks_queued),
      nativeTasksQueued: Int(snap.native_tasks_queued),
      pendingBytes: Int(snap.pending_bytes),
      maxTimers: Int(snap.max_timers),
      maxPendingTasks: Int(snap.max_pending_tasks),
      maxPendingBytes: Int(snap.max_pending_bytes))
  }

  public func snapshot() -> InstanceSnapshot? {
    return Engine.snapshot(identifier: id)
  }

  @discardableResult public func setAdmissionClass(_ cls: AdmissionClass) -> Bool {
    Engine.liveLock.lock()
    defer { Engine.liveLock.unlock() }
    guard isOpen, Engine.live[id]?.value === self else { return false }
    let native =
      cls == .background
      ? JSBAY_ADMISSION_BACKGROUND : JSBAY_ADMISSION_FOREGROUND
    return jsbay_engine_set_admission_class(id, native)
  }

  public func admissionClass() -> AdmissionClass {
    Engine.liveLock.lock()
    defer { Engine.liveLock.unlock() }
    guard isOpen, Engine.live[id]?.value === self else { return .foreground }
    var out = JSBAY_ADMISSION_FOREGROUND
    guard jsbay_engine_get_admission_class(id, &out) else { return .foreground }
    return out == JSBAY_ADMISSION_BACKGROUND ? .background : .foreground
  }

  public func isSuspended() -> Bool {
    Engine.liveLock.lock()
    defer { Engine.liveLock.unlock() }
    guard isOpen, Engine.live[id]?.value === self else { return false }
    return jsbay_engine_is_suspended(id)
  }
  public func requestInterrupt() -> Bool {
    Engine.liveLock.lock()
    defer { Engine.liveLock.unlock() }
    guard isOpen, Engine.live[id]?.value === self else { return false }
    return jsbay_engine_request_interrupt(id)
  }
  public func clearInterrupt() throws -> Bool {
    try requireOpen()
    return jsbay_engine_clear_interrupt(id)
  }
  public func setExecutionTimeLimit(milliseconds: UInt64) throws -> Bool {
    try requireOpen()
    return jsbay_engine_set_execution_time_limit(id, milliseconds)
  }
  public func setMemoryLimit(bytes: UInt64) throws -> Bool {
    try requireOpen()
    return jsbay_engine_set_memory_limit(id, bytes)
  }

  public func setResourceLimits(_ limits: ResourceLimits) throws -> Bool {
    try requireOpen()
    return try limits.withCLimits { jsbay_engine_set_resource_limits(id, $0) }
  }

  public func resourceUsage() throws -> ResourceUsage {
    try requireOpen()
    var usage = jsbay_resource_usage_t(
      struct_size: UInt32(MemoryLayout<jsbay_resource_usage_t>.size),
      timers: 0, tsfn_handles: 0, pending_calls: 0, native_tasks: 0, script_tasks: 0, pending_bytes: 0,
      max_timers: 0, max_tsfn_handles: 0, max_pending_calls: 0, max_pending_bytes: 0, max_pending_tasks: 0)
    guard jsbay_engine_get_resource_usage(id, &usage) else {
      throw JsBayError.status(JsBayStatus.invalidArgument)
    }
    return ResourceUsage(
      timers: usage.timers,
      tsfnHandles: usage.tsfn_handles,
      pendingCalls: usage.pending_calls,
      nativeTasks: usage.native_tasks,
      scriptTasks: usage.script_tasks,
      pendingBytes: usage.pending_bytes,
      limits: ResourceLimits(
        maxTimers: usage.max_timers,
        maxTsfnHandles: usage.max_tsfn_handles,
        maxPendingCalls: usage.max_pending_calls,
        maxPendingBytes: usage.max_pending_bytes,
        maxPendingTasks: usage.max_pending_tasks))
  }

  public static func globalResourceUsage() throws -> ResourceGlobalUsage {
    var usage = jsbay_resource_global_usage_t(
      struct_size: UInt32(MemoryLayout<jsbay_resource_global_usage_t>.size),
      timers: 0, tsfn_handles: 0, pending_calls: 0, native_tasks: 0, script_tasks: 0, pending_bytes: 0,
      max_timers: 0, max_tsfn_handles: 0, max_pending_calls: 0, max_native_tasks: 0, max_script_tasks: 0,
      max_pending_bytes: 0,
      fg_headroom_timers: 0, fg_headroom_tsfn_handles: 0, fg_headroom_pending_calls: 0,
      fg_headroom_native_tasks: 0, fg_headroom_script_tasks: 0, fg_headroom_pending_bytes: 0,
      bg_effective_max_timers: 0, bg_effective_max_tsfn_handles: 0, bg_effective_max_pending_calls: 0,
      bg_effective_max_native_tasks: 0, bg_effective_max_script_tasks: 0, bg_effective_max_pending_bytes: 0)
    guard jsbay_resource_global_usage(&usage) else {
      throw JsBayError.status(JsBayStatus.invalidArgument)
    }
    return ResourceGlobalUsage(
      timers: usage.timers,
      tsfnHandles: usage.tsfn_handles,
      pendingCalls: usage.pending_calls,
      nativeTasks: usage.native_tasks,
      scriptTasks: usage.script_tasks,
      pendingBytes: usage.pending_bytes,
      maxTimers: usage.max_timers,
      maxTsfnHandles: usage.max_tsfn_handles,
      maxPendingCalls: usage.max_pending_calls,
      maxNativeTasks: usage.max_native_tasks,
      maxScriptTasks: usage.max_script_tasks,
      maxPendingBytes: usage.max_pending_bytes,
      fgHeadroomTimers: usage.fg_headroom_timers,
      fgHeadroomTsfnHandles: usage.fg_headroom_tsfn_handles,
      fgHeadroomPendingCalls: usage.fg_headroom_pending_calls,
      fgHeadroomNativeTasks: usage.fg_headroom_native_tasks,
      fgHeadroomScriptTasks: usage.fg_headroom_script_tasks,
      fgHeadroomPendingBytes: usage.fg_headroom_pending_bytes,
      bgEffectiveMaxTimers: usage.bg_effective_max_timers,
      bgEffectiveMaxTsfnHandles: usage.bg_effective_max_tsfn_handles,
      bgEffectiveMaxPendingCalls: usage.bg_effective_max_pending_calls,
      bgEffectiveMaxNativeTasks: usage.bg_effective_max_native_tasks,
      bgEffectiveMaxScriptTasks: usage.bg_effective_max_script_tasks,
      bgEffectiveMaxPendingBytes: usage.bg_effective_max_pending_bytes)
  public struct MemoryUsage: Equatable {
    public var mallocCount: UInt64 = 0
    public var mallocSize: UInt64 = 0
    public var mallocLimit: UInt64 = 0
    public var memoryUsedCount: UInt64 = 0
    public var memoryUsedSize: UInt64 = 0
    public var atomCount: UInt64 = 0
    public var atomSize: UInt64 = 0
    public var objCount: UInt64 = 0
    public var objSize: UInt64 = 0
    public var shapeCount: UInt64 = 0
  }

  public func getMemoryUsage() throws -> MemoryUsage {
    try requireOpen()
    var raw = jsbay_memory_usage_t()
    raw.struct_size = UInt32(MemoryLayout<jsbay_memory_usage_t>.size)
    guard jsbay_engine_get_memory_usage(id, &raw) else {
      throw JsBayError.status(JsBayStatus.instanceNotFound)
    }
    return MemoryUsage(
      mallocCount: raw.malloc_count, mallocSize: raw.malloc_size, mallocLimit: raw.malloc_limit,
      memoryUsedCount: raw.memory_used_count, memoryUsedSize: raw.memory_used_size,
      atomCount: raw.atom_count, atomSize: raw.atom_size,
      objCount: raw.obj_count, objSize: raw.obj_size, shapeCount: raw.shape_count)
  }

  @discardableResult public func runGc() throws -> Bool {
    try requireOpen()
    return jsbay_engine_run_gc(id)
  }

  public typealias EventHandler = @convention(c) (UnsafePointer<jsbay_engine_event_t>?, UnsafeMutableRawPointer?) -> Void

  @discardableResult public func setEventHandler(
    _ handler: EventHandler?, userData: UnsafeMutableRawPointer? = nil
  ) throws -> Bool {
    try requireOpen()
    return jsbay_engine_set_event_handler(id, handler, userData)
  }

  /// Creates an `Engine` on a dedicated thread that runs its own `CFRunLoop`.
  /// The `ready` closure runs on that owner thread; keep all Engine/Value use there.
  public static func createOnBackground(id: Int32, ready: @escaping (Engine) -> Void) -> Thread {
    let thread = Thread {
      do {
        let engine = try Engine(id: id)
        ready(engine)
        CFRunLoopRun()
      } catch {
        // Host observes via ready not being called with a live engine; prefer setEventHandler for telemetry.
      }
    }
    thread.name = "jsbay-\(id)"
    thread.start()
    return thread
  }
  public func startInspector(port: UInt16 = 0) throws -> UInt16? {
    try requireOpen()
    var actual: UInt16 = 0
    return jsbay_engine_inspector_start(id, port, &actual) ? actual : nil
  }
  public func stopInspector() throws {
    try requireOpen()
    jsbay_engine_inspector_stop(id)
  }

  fileprivate func requireOwner() throws {
    guard pthread_equal(owner, pthread_self()) != 0 else { throw JsBayError.wrongThread }
  }
  fileprivate func requireOpen() throws {
    guard isOpen else { throw JsBayError.engineClosed }
    try requireOwner()
    if let loopRestoreFailure { throw JsBayError.status(loopRestoreFailure) }
    try requireOK(jsbay_engine_loop_status(id))
  }
  fileprivate func requireOK(_ status: jsbay_status_t) throws {
    if status.rawValue != JSBAY_OK.rawValue { throw JsBayError.status(Int32(status.rawValue)) }
  }
  fileprivate func requireSame(_ value: Value) throws {
    guard value.engine === self else { throw JsBayError.invalidValue }
    _ = try value.usableEngine()
  }
  fileprivate func simpleValue(_ body: (UnsafeMutablePointer<UInt64>) -> jsbay_status_t) throws
    -> Value
  {
    try requireOpen()
    var raw: UInt64 = 0
    try requireOK(body(&raw))
    guard raw != 0 else { throw JsBayError.status(-1) }
    return ownedValue(raw)
  }
  fileprivate func ownedValue(_ handle: UInt64) -> Value {
    let value = Value(engine: self, handle: handle)
    callbackScopes.last?.trackOwned(value)
    return value
  }
  fileprivate func valueResult(_ status: jsbay_status_t, _ value: UInt64, _ exception: UInt64)
    throws -> Value
  {
    if status.rawValue == JSBAY_OK.rawValue, value != 0, exception == 0 {
      return ownedValue(value)
    }
    if status.rawValue == JSBAY_EXCEPTION.rawValue, value == 0, exception != 0 {
      throw JsException(ownedValue(exception))
    }
    throw JsBayError.status(Int32(status.rawValue))
  }
  fileprivate func voidResult(_ status: jsbay_status_t, _ exception: UInt64) throws {
    if status.rawValue == JSBAY_OK.rawValue, exception == 0 { return }
    if status.rawValue == JSBAY_EXCEPTION.rawValue, exception != 0 {
      throw JsException(ownedValue(exception))
    }
    throw JsBayError.status(Int32(status.rawValue))
  }
  fileprivate func withUTF8<T>(_ string: String, _ body: (jsbay_utf8_t) throws -> T) rethrows -> T
  {
    try Array(string.utf8).withUnsafeBufferPointer { bytes in
      try body(jsbay_utf8_t(data: bytes.baseAddress, len: bytes.count))
    }
  }
  fileprivate func beginCallbackScope() -> CallbackScope {
    let scope = CallbackScope()
    callbackScopes.append(scope)
    return scope
  }
  fileprivate func endCallbackScope(_ scope: CallbackScope) {
    precondition(callbackScopes.last === scope, "JsBay callback scopes must unwind in order")
    _ = callbackScopes.popLast()
    scope.close()
  }

  fileprivate final class CallbackScope {
    private var owned: [Value] = []
    private var borrowed: [Value] = []
    func trackOwned(_ value: Value) { owned.append(value) }
    func trackBorrowed(_ value: Value) { borrowed.append(value) }
    func close() {
      for value in borrowed { value.invalidateBorrowed() }
      for value in owned { value.closeFromCallbackScope() }
      borrowed.removeAll()
      owned.removeAll()
    }
  }
}
}

private func jsbaySwiftCallback(
  _ instance: Int32, _ userData: UnsafeMutableRawPointer?, _ thisHandle: UInt64, _ argc: Int,
  _ args: UnsafePointer<UInt64>?, _ outValue: UnsafeMutablePointer<UInt64>?,
  _ outException: UnsafeMutablePointer<UInt64>?
) -> jsbay_status_t {
  guard let userData, let outValue, let outException else { return JSBAY_INVALID_ARGUMENT }
  let retained = Unmanaged<Engine.Binding>.fromOpaque(userData).retain()
  defer { retained.release() }
  outValue.pointee = 0
  outException.pointee = 0
  // The core guarantees this callback only while the engine exists. The temporary retain above also keeps the closure alive if close() is reentered.
  guard let engine = Engine.lookup(instance), engine.isOpen else {
    return JSBAY_INSTANCE_NOT_FOUND
  }
  let scope = engine.beginCallbackScope()
  defer { engine.endCallbackScope(scope) }
  let thisValue = Value(engine: engine, handle: thisHandle, ownership: .borrowed)
  scope.trackBorrowed(thisValue)
  let values: [Value]
  if let args {
    values = (0..<argc).map { index in
      let value = Value(engine: engine, handle: args[index], ownership: .borrowed)
      scope.trackBorrowed(value)
      return value
    }
  } else {
    values = []
  }
  do {
    outValue.pointee = try retained.takeUnretainedValue().callback(thisValue, values)
      .callbackHandle(for: engine)
    return JSBAY_OK
  } catch let error as JsException {
    do {
      outException.pointee = try error.value.callbackHandle(for: engine)
      return JSBAY_EXCEPTION
    } catch { return JSBAY_STALE_VALUE }
  } catch {
    do {
      outException.pointee = try engine.error(String(describing: error)).callbackHandle(for: engine)
      return JSBAY_EXCEPTION
    } catch { return JSBAY_OUT_OF_MEMORY }
  }
}

private func jsbaySwiftFinalize(_ userData: UnsafeMutableRawPointer?) {
  guard let userData else { return }
  Unmanaged<Engine.Binding>.fromOpaque(userData).release()
}

private func jsbaySwiftSyncStart(
  _ instance: Int32, _ userData: UnsafeMutableRawPointer?, _ requestID: UInt64,
  _ thisHandle: UInt64, _ argc: Int, _ args: UnsafePointer<UInt64>?
) {
  guard let userData else { return }
  let retained = Unmanaged<Engine.SyncBinding>.fromOpaque(userData).retain()
  defer { retained.release() }
  guard let engine = Engine.lookup(instance), engine.isOpen else { return }
  let scope = engine.beginCallbackScope()
  defer { engine.endCallbackScope(scope) }
  let thisValue = Value(engine: engine, handle: thisHandle, ownership: .borrowed)
  scope.trackBorrowed(thisValue)
  let values: [Value] =
    args.map { pointer in
      (0..<argc).map { index in
        let value = Value(engine: engine, handle: pointer[index], ownership: .borrowed)
        scope.trackBorrowed(value)
        return value
      }
    } ?? []
  retained.takeUnretainedValue().starter(thisValue, values, SyncCompletion(requestID))
}

private func jsbaySwiftSyncFinalize(_ userData: UnsafeMutableRawPointer?) {
  guard let userData else { return }
  Unmanaged<Engine.SyncBinding>.fromOpaque(userData).release()
}

private func jsbaySwiftLoopSchedule(
  _ userData: UnsafeMutableRawPointer?, _ delay: UInt64,
  _ task: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, _ taskData: UnsafeMutableRawPointer?
) -> Bool {
  guard let userData, let task else { return false }
  return Unmanaged<Engine.LoopBinding>.fromOpaque(userData).takeUnretainedValue().schedule(
    delay, task, taskData)
}

private func jsbaySwiftLoopCancel(_ userData: UnsafeMutableRawPointer?) {
  guard let userData else { return }
  Unmanaged<Engine.LoopBinding>.fromOpaque(userData).takeUnretainedValue().cancel()
}

extension Engine {
  fileprivate static var live: [Int32: WeakBox] = [:]
  fileprivate static let liveLock = NSLock()
  fileprivate final class WeakBox {
    weak var value: Engine?
    init(_ value: Engine) { self.value = value }
  }
  fileprivate static func lookup(_ id: Int32) -> Engine? {
    liveLock.lock()
    defer { liveLock.unlock() }
    return live[id]?.value
  }
  fileprivate static func isCurrentMainRunLoop() -> Bool {
    CFEqual(CFRunLoopGetCurrent(), CFRunLoopGetMain())
  }
  fileprivate static func isMainThread() -> Bool {
    pthread_main_np() != 0
  }
}
