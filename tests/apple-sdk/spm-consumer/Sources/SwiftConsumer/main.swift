import JsBaySDK

let engine = try Engine(id: 99101, allowMainRunLoopAttach: true)
defer { try? engine.close() }
let value = try engine.evaluate("6 * 7", filename: "spm-swift.js")
guard try value.number() == 42 else { fatalError("Swift SPM consumer failed") }
