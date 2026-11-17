import Foundation
import JsBaySDK

@main
struct DedicatedEngineThreadConsumer {
  static func main() async throws {
    let owner = try DedicatedEngineThread.start(id: 81_550)
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
