import CoreFoundation
import Foundation

public enum DedicatedEngineThreadError: Error, Equatable {
  case closed
  case timeout
  case javascript(JsExceptionDetails)
}

/// Marks data-only results that can safely leave a dedicated Engine thread. Custom conformances promise that the value contains no live Engine or Value handles.
public protocol EngineThreadResult: Sendable {}

extension Bool: EngineThreadResult {}
extension String: EngineThreadResult {}
extension Character: EngineThreadResult {}
extension Int: EngineThreadResult {}
extension Int8: EngineThreadResult {}
extension Int16: EngineThreadResult {}
extension Int32: EngineThreadResult {}
extension Int64: EngineThreadResult {}
extension UInt: EngineThreadResult {}
extension UInt8: EngineThreadResult {}
extension UInt16: EngineThreadResult {}
extension UInt32: EngineThreadResult {}
extension UInt64: EngineThreadResult {}
extension Float: EngineThreadResult {}
extension Double: EngineThreadResult {}
extension Data: EngineThreadResult {}
extension Date: EngineThreadResult {}
extension UUID: EngineThreadResult {}
extension URL: EngineThreadResult {}
extension JsBayError: EngineThreadResult {}
extension JsExceptionDetails: EngineThreadResult {}
extension DedicatedEngineThreadError: EngineThreadResult {}

extension Optional: EngineThreadResult where Wrapped: EngineThreadResult {}
extension Array: EngineThreadResult where Element: EngineThreadResult {}
extension Dictionary: EngineThreadResult where Key: EngineThreadResult, Value: EngineThreadResult {}
extension Set: EngineThreadResult where Element: EngineThreadResult {}
extension Result: EngineThreadResult
where Success: EngineThreadResult, Failure: Error & EngineThreadResult {}

/// Owns an Engine on one dedicated thread and serializes every operation on that thread.
public final class DedicatedEngineThread: @unchecked Sendable {
  private let worker: DedicatedEngineThreadWorker

  private init(worker: DedicatedEngineThreadWorker) { self.worker = worker }

  public static func start(id: Int32, limits: ResourceLimits? = nil) throws -> DedicatedEngineThread
  {
    DedicatedEngineThread(worker: try DedicatedEngineThreadWorker.start(id: id, limits: limits))
  }

  public func runOnOwner<T: EngineThreadResult>(
    _ operation: @escaping @Sendable (Engine) throws -> T
  ) throws
    -> T
  {
    try worker.runOnOwner(operation)
  }

  public func performOnOwner(_ operation: @escaping @Sendable (Engine) throws -> Void) throws {
    try worker.runOnOwner(operation)
  }

  public func run<T: EngineThreadResult>(
    _ operation: @escaping @Sendable (Engine) throws -> T
  ) async throws
    -> T
  {
    try await worker.run(operation)
  }

  public func perform(_ operation: @escaping @Sendable (Engine) throws -> Void) async throws {
    try await worker.run(operation)
  }

  public func post<T: EngineThreadResult>(
    _ operation: @escaping @Sendable (Engine) throws -> T,
    completion: @escaping @Sendable (Result<T, Error>) -> Void
  ) throws {
    try worker.post(operation, completion: completion)
  }

  public func postVoid(
    _ operation: @escaping @Sendable (Engine) throws -> Void,
    completion: @escaping @Sendable (Result<Void, Error>) -> Void
  ) throws {
    try worker.post(operation, completion: completion)
  }

  /// Requests asynchronous interruption of JavaScript execution on the dedicated thread. Safe to call from any thread.
  public func requestInterrupt() -> Bool {
    worker.requestInterrupt()
  }

  /// Cancels execution on the dedicated thread. Safe to call from any thread.
  public func cancel() -> Bool {
    worker.cancel()
  }

  /// Clears a previously requested user interrupt before executing more JavaScript.
  @discardableResult public func clearInterrupt() throws -> Bool {
    try runOnOwner { engine in
      try engine.clearInterrupt()
    }
  }

  /// Sets an execution time limit in milliseconds for upcoming work on the dedicated thread.
  @discardableResult public func setExecutionTimeLimit(milliseconds: UInt64) throws -> Bool {
    try runOnOwner { engine in
      try engine.setExecutionTimeLimit(milliseconds: milliseconds)
    }
  }

  /// Configures an execution budget in milliseconds applied to each outer evaluation.
  @discardableResult public func setExecutionBudget(milliseconds: UInt64) throws -> Bool {
    try runOnOwner { engine in
      try engine.setExecutionBudget(milliseconds: milliseconds)
    }
  }

  /// Configures the memory allocation limit in bytes.
  @discardableResult public func setMemoryLimit(bytes: UInt64) throws -> Bool {
    try runOnOwner { engine in
      try engine.setMemoryLimit(bytes: bytes)
    }
  }

  /// Stops accepting work, runs previously queued tasks, closes the Engine, and stops its run loop. Calling close from an owner-thread task schedules shutdown after work already in the queue and returns immediately.
  public func close(timeout: DispatchTimeInterval = .seconds(30)) throws {
    try worker.close(timeout: timeout)
  }

  deinit { try? worker.close() }
}

private final class DedicatedEngineThreadWorker: @unchecked Sendable {
  private enum State {
    case starting
    case running
    case closing
    case closed
  }

  private typealias Job = (Engine?) -> Void

  private let id: Int32
  private let limits: ResourceLimits?
  private let lock = NSLock()
  private let started = DispatchSemaphore(value: 0)
  private let shutdown = DispatchGroup()
  private var state = State.starting
  private var startupError: Error?
  private var engine: Engine?
  private var runLoop: CFRunLoop?
  private var keepAliveSource: CFRunLoopSource?
  private var jobs: [Job] = []
  private var drainScheduled = false
  private var isExecutingJob = false
  private var shutdownError: Error?
  private var shutdownCompleted = false
  private var thread: Thread!

  private init(id: Int32, limits: ResourceLimits?) {
    self.id = id
    self.limits = limits
    shutdown.enter()
  }

  /// Starts the owner thread, creates its Engine there, and returns after initialization succeeds or fails.
  static func start(id: Int32, limits: ResourceLimits?) throws -> DedicatedEngineThreadWorker {
    let owner = DedicatedEngineThreadWorker(id: id, limits: limits)
    owner.thread = Thread { [weak owner] in owner?.runOwnerLoop() }
    owner.thread.name = "jsbay-owner-\(id)"
    owner.thread.start()
    owner.started.wait()
    if let error = owner.startupError { throw error }
    return owner
  }

  /// Runs work synchronously on the owner thread. Calls made by an owner-thread task run inline to avoid deadlock.
  func runOnOwner<T: Sendable>(_ operation: @escaping @Sendable (Engine) throws -> T) throws
    -> T
  {
    if Thread.current === thread {
      lock.lock()
      let canRun: Bool
      switch state {
      case .running, .closing: canRun = true
      case .starting, .closed: canRun = false
      }
      lock.unlock()
      guard canRun, let engine else { throw DedicatedEngineThreadError.closed }
      return try operation(engine)
    }

    let result = OwnerResult<T>()
    try enqueue { engine in
      guard let engine else {
        result.set(.failure(DedicatedEngineThreadError.closed))
        return
      }
      do {
        result.set(.success(try operation(engine)))
      } catch {
        result.set(.failure(self.transferable(error)))
      }
    }
    return try result.wait()
  }

  /// Runs work asynchronously on the owner thread and returns only a Sendable result to the caller.
  func run<T: Sendable>(_ operation: @escaping @Sendable (Engine) throws -> T) async throws
    -> T
  {
    try await withCheckedThrowingContinuation { continuation in
      do {
        try post(operation) { result in continuation.resume(with: result) }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  /// Queues work on the owner thread and reports its result on that thread.
  func post<T: Sendable>(
    _ operation: @escaping @Sendable (Engine) throws -> T,
    completion: @escaping @Sendable (Result<T, Error>) -> Void
  ) throws {
    try enqueue { engine in
      guard let engine else {
        completion(.failure(DedicatedEngineThreadError.closed))
        return
      }
      do {
        completion(.success(try operation(engine)))
      } catch {
        completion(.failure(self.transferable(error)))
      }
    }
  }

  func requestInterrupt() -> Bool {
    lock.lock()
    let currentEngine = engine
    lock.unlock()
    return currentEngine?.requestInterrupt() ?? false
  }

  func cancel() -> Bool {
    lock.lock()
    let currentEngine = engine
    lock.unlock()
    return currentEngine?.cancel() ?? false
  }

  /// Stops accepting work, runs previously queued tasks, closes the Engine, and stops its run loop. Calling close from an owner-thread task schedules shutdown after work already in the queue and returns immediately.
  func close(timeout: DispatchTimeInterval = .seconds(30)) throws {
    lock.lock()
    switch state {
    case .starting:
      lock.unlock()
      if started.wait(timeout: .now() + timeout) == .timedOut {
        throw DedicatedEngineThreadError.timeout
      }
      try close(timeout: timeout)
      return
    case .running:
      state = .closing
      let currentEngine = engine
      let loop = runLoop
      let isBusy = isExecutingJob
      jobs.append { [weak self] _ in self?.finishShutdown() }
      scheduleDrainLocked(on: loop)
      lock.unlock()
      if Thread.current === thread {
        return
      }
      if isBusy {
        _ = currentEngine?.requestInterrupt()
      }
      if shutdown.wait(timeout: .now() + timeout) == .timedOut {
        _ = currentEngine?.cancel()
        throw DedicatedEngineThreadError.timeout
      }
      try throwShutdownErrorIfPresent()
    case .closing:
      let currentEngine = engine
      let isBusy = isExecutingJob
      lock.unlock()
      if Thread.current === thread {
        return
      }
      if isBusy {
        _ = currentEngine?.requestInterrupt()
      }
      if shutdown.wait(timeout: .now() + timeout) == .timedOut {
        _ = currentEngine?.cancel()
        throw DedicatedEngineThreadError.timeout
      }
      try throwShutdownErrorIfPresent()
    case .closed:
      lock.unlock()
      if Thread.current === thread { return }
      if shutdown.wait(timeout: .now() + timeout) == .timedOut {
        throw DedicatedEngineThreadError.timeout
      }
      try throwShutdownErrorIfPresent()
    }
  }

  private func enqueue(_ job: @escaping Job) throws {
    lock.lock()
    guard case .running = state, let runLoop else {
      lock.unlock()
      throw DedicatedEngineThreadError.closed
    }
    jobs.append(job)
    scheduleDrainLocked(on: runLoop)
    lock.unlock()
  }

  private func scheduleDrainLocked(on runLoop: CFRunLoop?) {
    guard !drainScheduled, let runLoop else { return }
    drainScheduled = true
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
      self?.drainJobs()
    }
    CFRunLoopWakeUp(runLoop)
  }

  private func drainJobs() {
    while true {
      lock.lock()
      guard !jobs.isEmpty else {
        drainScheduled = false
        lock.unlock()
        return
      }
      let job = jobs.removeFirst()
      let currentEngine = engine
      isExecutingJob = true
      lock.unlock()
      job(currentEngine)
      lock.lock()
      isExecutingJob = false
      if case .closing = state {
        _ = try? currentEngine?.clearInterrupt()
      }
      lock.unlock()
    }
  }

  private func finishShutdown() {
    lock.lock()
    let currentEngine = engine
    engine = nil
    state = .closed
    let loop = runLoop
    let source = keepAliveSource
    keepAliveSource = nil
    let pending = jobs
    jobs.removeAll(keepingCapacity: false)
    lock.unlock()

    var closeError: Error?
    do { try currentEngine?.close() } catch { closeError = error }

    lock.lock()
    shutdownError = closeError
    lock.unlock()

    if let loop, let source {
      CFRunLoopRemoveSource(loop, source, CFRunLoopMode.defaultMode)
      CFRunLoopSourceInvalidate(source)
      CFRunLoopStop(loop)
    }
    for job in pending { job(nil) }
  }

  private func throwShutdownErrorIfPresent() throws {
    lock.lock()
    let error = shutdownError
    lock.unlock()
    if let error { throw error }
  }

  private func transferable(_ error: Error) -> Error {
    guard let exception = error as? JsException else { return error }
    do {
      return DedicatedEngineThreadError.javascript(try exception.detailsAndClose())
    } catch {
      try? exception.value.close()
      return DedicatedEngineThreadError.closed
    }
  }

  private func runOwnerLoop() {
    do {
      engine = try Engine(id: id, limits: limits)
    } catch {
      lock.lock()
      startupError = error
      state = .closed
      let complete = !shutdownCompleted
      shutdownCompleted = true
      lock.unlock()
      started.signal()
      if complete { shutdown.leave() }
      return
    }

    let loop = CFRunLoopGetCurrent()
    var sourceContext = CFRunLoopSourceContext(
      version: 0,
      info: nil,
      retain: nil,
      release: nil,
      copyDescription: nil,
      equal: nil,
      hash: nil,
      schedule: nil,
      cancel: nil,
      perform: { _ in }
    )
    guard let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &sourceContext) else {
      let initializationError = DedicatedEngineThreadError.closed
      do { try engine?.close() } catch {
        lock.lock()
        shutdownError = error
        lock.unlock()
      }
      engine = nil
      lock.lock()
      startupError = shutdownError ?? initializationError
      state = .closed
      let complete = !shutdownCompleted
      shutdownCompleted = true
      lock.unlock()
      started.signal()
      if complete { shutdown.leave() }
      return
    }
    CFRunLoopAddSource(loop, source, CFRunLoopMode.defaultMode)
    lock.lock()
    runLoop = loop
    keepAliveSource = source
    state = .running
    lock.unlock()
    started.signal()
    CFRunLoopRun()

    var loopCloseError: Error?
    lock.lock()
    let lingeringEngine = engine
    engine = nil
    let lingeringSource = keepAliveSource
    keepAliveSource = nil
    lock.unlock()

    if let lingeringEngine {
      do { try lingeringEngine.close() } catch { loopCloseError = error }
    }
    if let lingeringSource {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), lingeringSource, CFRunLoopMode.defaultMode)
      CFRunLoopSourceInvalidate(lingeringSource)
    }
    lock.lock()
    state = .closed
    shutdownError = shutdownError ?? loopCloseError
    let pending = jobs
    jobs.removeAll(keepingCapacity: false)
    lock.unlock()
    for job in pending { job(nil) }
    lock.lock()
    let complete = !shutdownCompleted
    shutdownCompleted = true
    lock.unlock()
    if complete { shutdown.leave() }
  }
}

private final class OwnerResult<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private let ready = DispatchSemaphore(value: 0)
  private var result: Result<Value, Error>?

  func set(_ result: Result<Value, Error>) {
    lock.lock()
    self.result = result
    lock.unlock()
    ready.signal()
  }

  func wait() throws -> Value {
    ready.wait()
    lock.lock()
    let result = self.result
    lock.unlock()
    guard let result else { throw DedicatedEngineThreadError.closed }
    return try result.get()
  }
}
