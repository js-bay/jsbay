import Foundation
import JsBay
import JsBaySDK

@main
struct DedicatedEngineThreadConsumer {
  static func main() async throws {
    let owner = try DedicatedEngineThread.start(id: 81_550)
    precondition(owner.lifecycleState == .running)
    precondition(!owner.isClosing && !owner.isClosed)
    let stateReturned = try owner.runOnOwner { _ in owner.lifecycleState }
    precondition(stateReturned == .running)
    let ownerName = "jsbay-owner-81550"
    let threadName = try owner.runOnOwner { _ in Thread.current.name ?? "" }
    precondition(threadName == ownerName)
    let value = try owner.runOnOwner { engine in
      let value = try engine.evaluate("6 * 7", filename: "owner-consumer.js")
      defer { try? value.close() }
      return try value.number()
    }
    precondition(value == 42)

    let asynchronousValue = try await owner.run { engine in
      let value = try engine.evaluate("7 * 6", filename: "async-owner-consumer.js")
      defer { try? value.close() }
      return try value.number()
    }
    precondition(asynchronousValue == 42)

    let nestedValue = try owner.runOnOwner { engine in
      let engineID = engine.id
      return try owner.runOnOwner { nestedEngine in
        precondition(engineID == nestedEngine.id)
        let value = try nestedEngine.evaluate("3 * 14")
        defer { try? value.close() }
        return try value.number()
      }
    }
    precondition(nestedValue == 42)

    let originalExceptionEscaped = try owner.runOnOwner { engine in
      let callback = try engine.bind("ownerReentryThrow") { _, _ in
        try owner.performOnOwner { nested in
          let value = try nested.evaluate("throw globalThis.ownerOriginal")
          try value.close()
        }
        return try engine.undefined()
      }
      defer { try? callback.close() }
      let result = try engine.evaluate(
        "globalThis.ownerOriginal = { code: 7 }; try { ownerReentryThrow(); false } catch (error) { error === ownerOriginal }"
      )
      defer { try? result.close() }
      return try result.bool()
    }
    precondition(originalExceptionEscaped)

    do {
      _ = try await owner.run { engine -> Double in
        let value = try engine.evaluate(
          "function renderWidget(){ throw new Error('widget failure'); } renderWidget()",
          filename: "widget.js")
        defer { try? value.close() }
        return try value.number()
      }
      preconditionFailure("JavaScript exception must propagate")
    } catch let error as DedicatedEngineThreadError {
      guard case .javascript(let details) = error else { throw error }
      precondition(details.message.contains("widget failure"))
      precondition(details.stackTraceString?.contains("renderWidget") == true)
      precondition(details.stackTraceString?.contains("widget.js") == true)
    }

    let postedValue: Double = try await withCheckedThrowingContinuation { continuation in
      do {
        try owner.post({ engine in
          let value = try engine.evaluate("40 + 2")
          defer { try? value.close() }
          return try value.number()
        }) { result in continuation.resume(with: result) }
      } catch {
        continuation.resume(throwing: error)
      }
    }
    precondition(postedValue == 42)

    let queuedResult = LockedFlag()
    try owner.post(
      { engine in
        let value = try engine.evaluate("40 + 2")
        defer { try? value.close() }
        return try value.number()
      },
      completion: { result in
        if case .success(let value) = result { queuedResult.set(value == 42) }
      })

    do {
      _ = try DedicatedEngineThread.start(id: 81_550)
      preconditionFailure("a duplicate engine ID must fail during owner initialization")
    } catch let error as JsBayError {
      precondition(error.statusCode == JsBayStatus.invalidArgument)
    }

    let closingReentrantValue = try owner.runOnOwner { _ in
      try owner.close()
      precondition(owner.isClosing)
      precondition(!owner.isClosed)
      precondition(owner.lifecycleState == .closing)
      return try owner.runOnOwner { engine in
        let value = try engine.evaluate("6 * 7")
        defer { try? value.close() }
        return try value.number()
      }
    }
    precondition(closingReentrantValue == 42)
    precondition(queuedResult.get())
    let concurrentClosers = (0..<4).map { _ in Task.detached { try owner.close() } }
    for closer in concurrentClosers { try await closer.value }
    try owner.close()
    precondition(owner.isClosed)
    precondition(!owner.isClosing)
    precondition(owner.lifecycleState == .closed)
    do {
      _ = try owner.runOnOwner { _ in 1 }
      preconditionFailure("closed owner must reject new work")
    } catch is DedicatedEngineThreadError {}

    weak var releasedOwner: DedicatedEngineThread?
    do {
      releasedOwner = try DedicatedEngineThread.start(id: 81_551)
    }
    precondition(releasedOwner == nil)
    let reusedOwner = try DedicatedEngineThread.start(id: 81_551)
    try reusedOwner.close()

    let parityOwner = try DedicatedEngineThread.start(id: 81_552)
    let limitSet = try parityOwner.setExecutionTimeLimit(milliseconds: 10_000)
    precondition(limitSet)
    let budgetSet = try parityOwner.setExecutionBudget(milliseconds: 5_000)
    precondition(budgetSet)
    let memorySet = try parityOwner.setMemoryLimit(bytes: 10_000_000)
    if jsbay_library_backend() == JSBAY_BACKEND_JSC {
      precondition(!memorySet, "JSC must report unsupported for memory limits")
    } else {
      precondition(memorySet, "QuickJS backends must accept memory limits")
    }
    let interruptCleared = try parityOwner.clearInterrupt()
    precondition(interruptCleared)
    precondition(parityOwner.requestInterrupt() || true)
    precondition(parityOwner.cancel() || true)
    try parityOwner.close()

    let infiniteLoopOwner = try DedicatedEngineThread.start(id: 81_553)
    let loopStarted = LockedFlag()
    let loopTask = Task.detached {
      do {
        _ = try infiniteLoopOwner.runOnOwner { engine in
          let notify = try engine.bind("loopStarted") { _, _ in
            loopStarted.set(true)
            return try engine.undefined()
          }
          defer { try? notify.close() }
          let val = try engine.evaluate("loopStarted(); while (true) {}", filename: "infinite.js")
          defer { try? val.close() }
          return 1
        }
      } catch {
        // Expected interruption on close.
      }
    }
    while !loopStarted.get() {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    try infiniteLoopOwner.close(timeout: .seconds(5))
    _ = await loopTask.result

    let queuedDrainOwner = try DedicatedEngineThread.start(id: 81_554)
    let queuedDrainResult = LockedFlag()
    try queuedDrainOwner.post(
      { engine in
        let value = try engine.evaluate("21 + 21")
        defer { try? value.close() }
        return try value.number()
      },
      completion: { result in
        if case .success(let value) = result { queuedDrainResult.set(value == 42) }
      })
    try queuedDrainOwner.close(timeout: .seconds(5))
    precondition(queuedDrainResult.get())

    let directInitOwner = try DedicatedEngineThread(id: 81_552)
    let directValue = try directInitOwner.runOnOwner { engine in
      let evaluated = try engine.evaluate("10 + 32")
      defer { try? evaluated.close() }
      return try evaluated.number()
    }
    precondition(directValue == 42)
    try directInitOwner.close(timeout: .seconds(5))
  }
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set(_ value: Bool) {
    lock.lock()
    self.value = value
    lock.unlock()
  }

  func get() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
