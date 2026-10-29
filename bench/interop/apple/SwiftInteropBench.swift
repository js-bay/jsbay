import Dispatch
import Foundation
import JsBaySDK

private let warmup = 100
private let iterations = 1000
private let payloadSize = 4096

private func elapsed(_ count: Int = iterations, _ operation: () throws -> Void) throws -> UInt64 {
  for _ in 0..<warmup { try operation() }
  let start = DispatchTime.now().uptimeNanoseconds
  for _ in 0..<count { try operation() }
  return DispatchTime.now().uptimeNanoseconds - start
}

private func number(_ engine: Engine, _ source: String) throws {
  let value = try engine.evaluate(source, filename: "interop.js")
  defer { try? value.close() }
  guard try value.number() == 42 else { throw JsBayError.status(JsBayStatus.invalidArgument) }
}

private func lifecycle() throws -> UInt64 {
  for index in 0..<warmup {
    let engine = try Engine(id: Int32(1_500_000 + index))
    defer { try? engine.close() }
    try number(engine, "42")
  }
  let start = DispatchTime.now().uptimeNanoseconds
  for index in 0..<100 {
    do {
      let engine = try Engine(id: Int32(1_500_100 + index))
      defer { try? engine.close() }
      try number(engine, "42")
    }
  }
  return DispatchTime.now().uptimeNanoseconds - start
}

do {
  let engine = try Engine(id: 1_400_001)
  defer { try? engine.close() }
  let callback = try engine.bind("benchCallback") { _, _ in try engine.number(42) }
  defer { try? callback.close() }
  let eval = try elapsed { try number(engine, "var n=0; for(var i=0;i<64;i++)n+=i; 42") }
  let callbackTime = try elapsed { try number(engine, "benchCallback()") }
  let textJSON = try elapsed {
    let value = try engine.evaluate("({text:'public interop',count:42})", filename: "text-json.js")
    defer { try? value.close() }
    guard try value.json() == "{\"text\":\"public interop\",\"count\":42}" else {
      throw JsBayError.status(JsBayStatus.invalidArgument)
    }
  }
  let input = Data(repeating: 7, count: payloadSize)
  let buffer = try elapsed {
    let value = try engine.arrayBuffer(input)
    defer { try? value.close() }
    guard try value.bytes() == input else { throw JsBayError.status(JsBayStatus.invalidArgument) }
  }
  let life = try lifecycle()
  print("\(eval) \(callbackTime) \(textJSON) \(buffer) \(life)")
} catch {
  fputs("Swift interop benchmark failed: \(error)\n", stderr)
  exit(2)
}
