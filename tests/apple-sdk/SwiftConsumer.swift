import Dispatch
import Foundation
import JsBaySDK

// This is an executable consumer, not an SDK-internal unit test. The Apple package test compiles and runs it against the packaged archive.
struct SwiftConsumer {
  static func run() throws {
    let engine = try Engine(id: 81_001, allowMainRunLoopAttach: true)
    defer { try? engine.close() }
    do {
      _ = try Engine(id: 81_090)
      fatalError("main run loop attach must be refused without opt-in")
    } catch let error as JsBayError {
      guard error.statusCode == JsBayStatus.invalidArgument else { throw error }
    }
    do {
      _ = try Engine(id: 81_001, allowMainRunLoopAttach: true)
      fatalError("duplicate engine ID was accepted")
    } catch let error as JsBayError {
      guard error.statusCode == JsBayStatus.invalidArgument else { throw error }
    }
    guard try engine.evaluate("40+2", filename: "duplicate-id.js").number() == 42 else {
      fatalError("duplicate create disturbed the original engine")
    }
    let sync = try engine.bindSync("swiftSync", timeoutMilliseconds: 1_000) { _, _, completion in
      DispatchQueue.global().async { try? completion.resolveString("42") }
    }
    defer { try? sync.close() }
    guard try engine.evaluate("Number(swiftSync())", filename: "sync.js").number() == 42 else {
      fatalError("sync completion mismatch")
    }

    let cache = Engine.CacheOptions(directory: NSTemporaryDirectory(), version: "swift-consumer-v1")
    let object = try engine.evaluate(
      "({ text: 'hi\\u0000😀', add(a,b) { return a + b } })", filename: "consumer.js", cache: cache)
    let text = try object.get("text")
    guard try text.string() == "hi\u{0000}😀" else { fatalError("UTF-8 value mismatch") }
    let directNul = try engine.string("swift\u{0000}😀")
    guard try directNul.string() == "swift\u{0000}😀" else {
      fatalError("embedded NUL input mismatch")
    }
    var input = Data([0, 1, 255, 0])
    let binary = try engine.arrayBuffer(input)
    input[1] = 99
    guard try binary.bytes() == Data([0, 1, 255, 0]) else { fatalError("buffer copy-in isolation") }
    var output = try binary.bytes()
    output[1] = 88
    guard try binary.bytes() == Data([0, 1, 255, 0]) else {
      fatalError("buffer copy-out isolation")
    }
    guard try engine.arrayBuffer(Data()).bytes().isEmpty else { fatalError("empty buffer") }
    guard
      try engine.evaluate("new DataView(new Uint8Array([8,9,0,255,7]).buffer,2,2)").bytes()
        == Data([0, 255])
    else { fatalError("buffer view window") }

    let cacheProbe = Engine.CacheOptions(
      directory: NSTemporaryDirectory(), version: UUID().uuidString)
    let first = try engine.evaluate(
      "globalThis.__swiftCache = (globalThis.__swiftCache || 0) + 1; __swiftCache",
      filename: "cache-probe.js", cache: cacheProbe)
    guard try first.number() == 1, !cacheProbe.didHit else { fatalError("cold cache mismatch") }
    let second = try engine.evaluate(
      "globalThis.__swiftCache = (globalThis.__swiftCache || 0) + 1; __swiftCache",
      filename: "cache-probe.js", cache: cacheProbe)
    #if JSBAY_NO_BYTECODE_CACHE
      let expectedHit = false
    #else
      let expectedHit = true
    #endif
    guard try second.number() == 2, cacheProbe.didHit == expectedHit else {
      fatalError("warm cache or single-execution mismatch")
    }

    let add = try object.get("add")
    let one = try engine.number(1)
    let two = try engine.number(2)
    let sum = try add.call(this: object, arguments: [one, two])
    guard try sum.number() == 3 else { fatalError("live function value mismatch") }

    // Object operations: construct, has, delete, keys, instanceOf.
    func thrownValue(_ label: String, _ body: () throws -> Void) throws -> Value {
      do {
        try body()
        fatalError("\(label) did not throw")
      } catch let error as JsException {
        return error.value
      }
    }
    func requireTypeError(_ label: String, _ body: () throws -> Void) throws {
      let thrown = try thrownValue(label, body)
      guard try thrown.get("name").string() == "TypeError" else {
        fatalError("\(label) must throw TypeError")
      }
    }
    let point = try engine.evaluate("(function P(x) { this.x = x })", filename: "construct.js")
    let constructed = try point.construct(arguments: [try engine.number(42)])
    guard try constructed.get("x").number() == 42, try constructed.instanceOf(point) else {
      fatalError("construct did not run the constructor")
    }
    guard
      try engine.evaluate("(function Q() { this.n = arguments.length })").construct()
        .get("n").number() == 0
    else { fatalError("construct default arguments mismatch") }
    let throwingConstructor = try engine.evaluate(
      "(function B() { throw new Error('ctor boom') })", filename: "construct-throw.js")
    let constructorError = try thrownValue("throwing constructor") {
      _ = try throwingConstructor.construct()
    }
    guard try constructorError.get("message").string() == "ctor boom" else {
      fatalError("construct exception value mismatch")
    }
    let arrowFunction = try engine.evaluate("(() => 1)", filename: "construct-arrow.js")
    try requireTypeError("construct of non-constructor") { _ = try arrowFunction.construct() }

    let target = try engine.evaluate(
      "({ a: 1, get g() { return 1 } })", filename: "has-target.js")
    guard try target.has("a"), try target.has("g"), try target.has("toString"),
      try !target.has("missing")
    else { fatalError("has own, accessor, inherited, or missing mismatch") }
    try requireTypeError("has on a non-object") { _ = try one.has("a") }
    let trapped = try engine.evaluate(
      "new Proxy({}, { has() { throw new Error('has trap') } })", filename: "has-trap.js")
    let trapError = try thrownValue("has trap") { _ = try trapped.has("a") }
    guard try trapError.get("message").string() == "has trap" else {
      fatalError("has trap exception value mismatch")
    }

    let deletable = try engine.evaluate(
      """
      (() => {
        const o = { a: 1 };
        Object.defineProperty(o, 'fixed', { value: 1, configurable: false });
        return o;
      })()
      """, filename: "delete-target.js")
    guard try deletable.delete("a"), try !deletable.has("a") else {
      fatalError("delete of a configurable property mismatch")
    }
    guard try !deletable.delete("fixed"), try deletable.has("fixed") else {
      fatalError("delete of a non-configurable property must report false")
    }
    guard try deletable.delete("missing") else { fatalError("delete of a missing key mismatch") }
    let undefinedValue = try engine.undefined()
    try requireTypeError("delete on undefined") { _ = try undefinedValue.delete("a") }

    let keyed = try engine.evaluate(
      """
      (() => {
        const proto = { inherited: 1 };
        const o = Object.create(proto);
        o.b = 1; o[2] = 1; o.a = 1; o[1] = 1;
        Object.defineProperty(o, 'hidden', { value: 1, enumerable: false });
        o[Symbol('s')] = 1;
        return o;
      })()
      """, filename: "keys-target.js")
    guard try keyed.keys().json() == "[\"1\",\"2\",\"b\",\"a\"]" else {
      fatalError("keys must be own enumerable string keys, integers first")
    }
    let nullValue = try engine.null()
    try requireTypeError("keys on null") { _ = try nullValue.keys() }

    let customInstance = try engine.evaluate(
      "(class { static [Symbol.hasInstance](v) { return v === 7 } })",
      filename: "has-instance.js")
    guard try !one.instanceOf(customInstance), try engine.number(7).instanceOf(customInstance)
    else { fatalError("Symbol.hasInstance result mismatch") }
    let list = try engine.evaluate("[]", filename: "instance-list.js")
    guard try list.instanceOf(try engine.evaluate("Array")),
      try !list.instanceOf(try engine.evaluate("Function"))
    else { fatalError("instanceOf prototype chain mismatch") }
    let plainObject = try engine.evaluate("({})", filename: "instance-plain.js")
    try requireTypeError("instanceOf non-callable") { _ = try list.instanceOf(plainObject) }

    let host = try engine.bind("swiftObject") { _, _ in
      let result = try engine.object()
      try result.set("fromSwift", to: try engine.bool(true))
      return result
    }
    _ = host
    let nativeObject = try engine.evaluate("swiftObject()", filename: "native.js")
    guard try nativeObject.get("fromSwift").bool() else { fatalError("native object mismatch") }

    var borrowedArgument: Value?
    var escapedArgument: Value?
    _ = try engine.bind("swiftCapture") { _, arguments in
      borrowedArgument = arguments[0]
      do {
        try arguments[0].close()
        fatalError("borrowed callback argument close succeeded")
      } catch let error as JsBayError {
        guard error.statusCode == JsBayStatus.invalidArgument else { throw error }
      }
      escapedArgument = try arguments[0].retain()
      return try engine.undefined()
    }
    _ = try engine.evaluate("swiftCapture(9)", filename: "borrowed.js")
    do {
      _ = try borrowedArgument?.number()
      fatalError("borrowed callback argument escaped")
    } catch let error as JsBayError {
      guard error.statusCode == JsBayStatus.staleValue else { throw error }
    }
    guard let borrowedArgument else { fatalError("missing borrowed callback argument") }
    do {
      try borrowedArgument.close()
      fatalError("expired borrowed callback argument close succeeded")
    } catch let error as JsBayError {
      guard error.statusCode == JsBayStatus.staleValue else { throw error }
    }
    _ = try engine.bind("swiftBorrowedDescription") { thisValue, _ in
      do {
        _ = try engine.exception(thisValue).describeAndClose()
        fatalError("borrowed exception description succeeded")
      } catch let error as JsBayError {
        guard error.statusCode == JsBayStatus.invalidArgument else { throw error }
      }
      return try engine.undefined()
    }
    _ = try engine.evaluate("swiftBorrowedDescription()", filename: "borrowed-description.js")
    guard try escapedArgument?.number() == 9 else {
      fatalError("retained callback argument did not escape")
    }

    _ = try engine.bind("swiftInner") { _, _ in try engine.object() }
    _ = try engine.bind("swiftOuter") { _, _ in
      try engine.evaluate("swiftInner()", filename: "nested.js")
    }
    guard try (try engine.evaluate("swiftOuter()", filename: "outer.js")).type() == .object else {
      fatalError("nested callback scope mismatch")
    }
    guard try engine.evaluate("Symbol('kind')", filename: "symbol-kind.js").type() == .symbol,
      try engine.evaluate("1n", filename: "bigint-kind.js").type() == .bigInt
    else {
      fatalError("symbol and bigint kinds mismatch")
    }

    var setterException: Value?
    _ = try engine.bind("swiftSetterThrow") { _, _ in
      let object = try engine.evaluate("({set x(v) { throw 19 }})")
      do {
        try object.set("x", to: try engine.number(1))
        fatalError("setter must throw")
      } catch let error as JsException { setterException = error.value }
      return try engine.undefined()
    }
    _ = try engine.evaluate("swiftSetterThrow()")
    do {
      _ = try setterException?.number()
      fatalError("setter exception escaped callback scope")
    } catch JsBayError.invalidValue {}

    _ = try engine.bind("swiftThrow") { _, _ in throw CocoaError(.fileNoSuchFile) }
    do {
      _ = try engine.evaluate("swiftThrow()", filename: "throw.js")
      fatalError("expected JS exception")
    } catch let error as JsException {
      _ = try error.value.string()
    }

    _ = try engine.bind("throwSeven") { _, _ in throw try engine.exception(try engine.number(7)) }
    do {
      _ = try engine.evaluate("throwSeven()", filename: "throw-seven.js")
      fatalError("expected arbitrary throw")
    } catch let error as JsException {
      guard try error.value.number() == 7 else { fatalError("arbitrary throw changed value") }
    }

    do {
      _ = try engine.evaluate("throw 'swift-display\\u0000😀'", filename: "describe-and-close.js")
      fatalError("expected description source")
    } catch let error as JsException {
      guard try error.describeAndClose() == "swift-display\u{0000}😀" else {
        fatalError("consuming description text")
      }
      do {
        _ = try error.value.string()
        fatalError("consumed exception value survived")
      } catch let status as JsBayError {
        guard status.statusCode == JsBayStatus.staleValue else { throw status }
      }
    }
    do {
      _ = try engine.evaluate(
        "throw { toString() { throw 9 } }", filename: "describe-and-close-secondary.js")
      fatalError("expected secondary description source")
    } catch let error as JsException {
      guard try error.describeAndClose() == "JavaScript exception" else {
        fatalError("secondary description fallback")
      }
      do {
        _ = try error.value.string()
        fatalError("secondary consumed exception value survived")
      } catch let status as JsBayError {
        guard status.statusCode == JsBayStatus.staleValue else { throw status }
      }
    }

    let saved = try object.retain()
    try object.close()
    try object.close()
    _ = try saved.get("text")
    try saved.close()
    var automaticTimerCount = 0
    _ = try engine.bind("swiftAutomaticTimer") { _, _ in
      automaticTimerCount += 1
      return try engine.undefined()
    }
    _ = try engine.evaluate("setTimeout(swiftAutomaticTimer, 1)", filename: "automatic-timer.js")
    _ = try engine.evaluate(
      "setTimeout(swiftAutomaticTimer, 2)", filename: "automatic-timer-next.js")
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
    guard automaticTimerCount == 2 else { fatalError("CFRunLoop driver did not run both timers") }

    let pending = try Engine(id: 81_006, allowMainRunLoopAttach: true)
    var closedTimerFired = false
    _ = try pending.bind("swiftClosedTimer") { _, _ in
      closedTimerFired = true
      return try pending.undefined()
    }
    _ = try pending.evaluate("setTimeout(swiftClosedTimer, 1)", filename: "closed-timer.js")
    try pending.close()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    guard !closedTimerFired else { fatalError("closed engine ran a pending timer") }

    _ = try engine.bind("swiftStopLoop") { _, _ in
      guard engine.stopLoop() else { fatalError("stopLoop rejected active runLoop") }
      return try engine.undefined()
    }
    _ = try engine.evaluate("setTimeout(swiftStopLoop, 1)", filename: "blocking-loop.js")
    try engine.runLoop()

    var rejectedNestedRunLoop = false
    var recoveredTimerCount = 0
    _ = try engine.bind("swiftRejectedRunLoop") { _, _ in
      do {
        try engine.runLoop()
        fatalError("runLoop from a callback unexpectedly succeeded")
      } catch let error as JsBayError {
        guard error.statusCode == JsBayStatus.invalidArgument else { throw error }
        rejectedNestedRunLoop = true
      }
      return try engine.undefined()
    }
    _ = try engine.bind("swiftRecoveredTimer") { _, _ in
      recoveredTimerCount += 1
      return try engine.undefined()
    }
    _ = try engine.evaluate(
      "swiftRejectedRunLoop(); setTimeout(swiftRecoveredTimer, 1)", filename: "rejected-run-loop.js"
    )
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
    guard rejectedNestedRunLoop, recoveredTimerCount == 1 else {
      fatalError("rejected runLoop did not restore the automatic driver")
    }

    let other = try Engine(id: 81_003, allowMainRunLoopAttach: true)
    defer { try? other.close() }
    let wrongThreadDone = DispatchSemaphore(value: 0)
    var rejectedWrongThread = false
    DispatchQueue.global().async {
      defer { wrongThreadDone.signal() }
      do { _ = try engine.number(1) } catch let error as JsBayError {
        rejectedWrongThread = error.statusCode == JsBayStatus.wrongThread
      } catch {}
    }
    _ = wrongThreadDone.wait(timeout: .now() + 5)
    guard rejectedWrongThread else { fatalError("owner-thread check accepted foreign thread") }
    let foreign = try other.number(1)
    do {
      try nativeObject.set("foreign", to: foreign)
      fatalError("cross-engine value accepted")
    } catch JsBayError.invalidValue {}
    do {
      _ = try point.construct(arguments: [foreign])
      fatalError("cross-engine construct argument accepted")
    } catch JsBayError.invalidValue {}
    do {
      _ = try target.instanceOf(foreign)
      fatalError("cross-engine instanceOf constructor accepted")
    } catch JsBayError.invalidValue {}
    _ = try engine.bind("foreignCallback") { _, _ in foreign }
    do {
      _ = try engine.evaluate("foreignCallback()", filename: "foreign-callback.js")
      fatalError("foreign callback value accepted")
    } catch {}

    let closing = try Engine(id: 81_005, allowMainRunLoopAttach: true)
    let closingValue = try closing.number(1)
    _ = try closing.bind("closeDuringCallback") { _, arguments in
      try closing.close()
      return arguments[0]
    }
    _ = try? closing.evaluate("closeDuringCallback(7)", filename: "close-callback.js")
    do {
      _ = try closingValue.number()
      fatalError("callback close left a live value")
    } catch {}

    try runP0KeepAlive()

    let old = try engine.number(22)
    try engine.close()
    try engine.close()
    do {
      _ = try old.number()
      fatalError("value survived engine close")
    } catch let error as JsBayError {
      guard error.statusCode == JsBayStatus.staleValue else { throw error }
    }
    let replacement = try Engine(id: engine.id, allowMainRunLoopAttach: true)
    defer { try? replacement.close() }
    guard !engine.stopLoop() else {
      fatalError("closed engine stopped same-id replacement")
    }
    _ = try replacement.bind("replacementStopLoop") { _, _ in
      guard replacement.stopLoop() else { fatalError("replacement stopLoop was rejected") }
      return try replacement.undefined()
    }
    _ = try replacement.evaluate(
      "setTimeout(replacementStopLoop, 1)", filename: "replacement-stop-loop.js")
    try replacement.runLoop()
    guard !engine.requestInterrupt() else {
      fatalError("closed engine interrupted same-id replacement")
    }
    let replacementValue = try replacement.evaluate("40+2", filename: "replacement.js")
    guard try replacementValue.number() == 42 else {
      fatalError("same-id replacement did not evaluate")
    }
    try replacementValue.close()
  }

  /// Device/simulator P0: soft-cancel suspend/resume, admission class, typed sync bytes.
  static func runP0KeepAlive() throws {
    let engine = try Engine(id: 81_050, allowMainRunLoopAttach: true)
    defer { try? engine.close() }

    _ = try engine.evaluate("globalThis.__p0Keep = 42", filename: "p0-keep.js")
    var fired = false
    _ = try engine.bind("afterResume") { _, _ in
      fired = true
      guard engine.stopLoop() else { fatalError("P0 stopLoop after resume rejected") }
      return try engine.undefined()
    }
    _ = try engine.evaluate("setTimeout(afterResume, 50)", filename: "p0-suspend.js")
    guard engine.suspendLoop() else { fatalError("P0 suspendLoop failed") }
    guard engine.isSuspended() else { fatalError("P0 isSuspended after suspend") }
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    guard !fired else { fatalError("P0 timer fired while suspended") }
    guard try engine.evaluate("globalThis.__p0Keep", filename: "p0-keep-check.js").number() == 42
    else {
      fatalError("P0 VM content lost while suspended")
    }
    guard engine.resumeLoop() else { fatalError("P0 resumeLoop failed") }
    try engine.runLoop()
    guard fired else { fatalError("P0 timer did not fire after resume") }
    guard !engine.isSuspended() else { fatalError("P0 still suspended after resume") }

    guard engine.admissionClass() == .foreground else {
      fatalError("P0 default admission class")
    }
    guard engine.setAdmissionClass(.background) else { fatalError("P0 set BACKGROUND") }
    guard engine.admissionClass() == .background else { fatalError("P0 get BACKGROUND") }
    let global = try Engine.globalResourceUsage()
    guard global.fgHeadroomTimers >= 0, global.bgEffectiveMaxTimers <= global.maxTimers else {
      fatalError("P0 headroom inconsistent")
    }
    guard global.fgHeadroomTimers > 0 || global.maxTimers < 4 else {
      fatalError("P0 expected FG timer headroom")
    }
    guard engine.setAdmissionClass(.foreground) else { fatalError("P0 set FOREGROUND") }
    let listed = Engine.listEngines()
    guard listed.contains(engine.id) else { fatalError("P0 listEngines missing id") }
    guard let snap = engine.snapshot(), snap.instanceId == engine.id else {
      fatalError("P0 snapshot missing")
    }

    let syncBytes = try engine.bindSync("p0SyncBytes", timeoutMilliseconds: 2_000) {
      _, _, completion in
      DispatchQueue.global().async { try? completion.resolveBytes([9, 8, 7]) }
    }
    defer { try? syncBytes.close() }
    guard
      try engine.evaluate(
        """
        (function(){ var u = new Uint8Array(p0SyncBytes()); return u.length===3 && u[0]===9 && u[1]===8 && u[2]===7 })()
        """,
        filename: "p0-sync-bytes.js"
      ).bool()
    else {
      fatalError("P0 ResolveBytes mismatch")
    }
    print("PASS: Apple P0 keep-alive (suspend/admission/sync-bytes)")
  }

}

#if JSBAY_SDK_APP_CONSUMER
  @_cdecl("jsbay_swift_sdk_probe")
  public func jsbaySwiftSDKProbe() -> Int32 {
    do {
      try SwiftConsumer.run()
      return 0
    } catch {
      NSLog("Swift SDK consumer failed: %@", String(describing: error))
      return 1
    }
  }
#else
  @main
  struct SwiftConsumerMain {
    static func main() throws {
      try SwiftConsumer.run()
      print("PASS: Swift SDK consumer")
    }
  }
#endif
