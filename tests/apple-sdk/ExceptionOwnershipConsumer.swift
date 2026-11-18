import Foundation
import JsBaySDK

private final class DeallocationCount: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }
}

@main
struct ExceptionOwnershipConsumer {
  static func main() throws {
    let engine = try Engine(id: 82_001, allowMainRunLoopAttach: true)
    defer { try? engine.close() }

    let deallocationCount = DeallocationCount()
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    let buffer = try engine.arrayBufferNoCopy(bytes: bytes, count: 1) { pointer, _ in
      pointer.deallocate()
      deallocationCount.increment()
    }
    let global = try engine.global()
    try global.set("releaseProbe", to: buffer)
    try buffer.close()
    try global.close()

    do {
      _ = try engine.evaluate(
        "globalThis.releaseProbe.toString = function(){throw 8}; throw {message:'failure', get stack(){const value = globalThis.releaseProbe; delete globalThis.releaseProbe; return value}}",
        filename: "temporary-field.js")
      fatalError("expected JavaScript exception")
    } catch let error as JsException {
      _ = try error.details()
      guard deallocationCount.count == 1 else {
        fatalError("throwing stack conversion must release its temporary buffer value")
      }
      let message = try error.value.get("message")
      defer { try? message.close() }
      guard try message.string() == "failure" else {
        fatalError("exception details must preserve the original thrown value")
      }
      _ = try error.detailsAndClose()
    }
    print("Swift exception temporary ownership: PASS")
  }
}
