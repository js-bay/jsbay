import JsBaySDK

func returnValueAcrossThreads(_ owner: DedicatedEngineThread) async throws -> Value {
  try await owner.run { engine in try engine.evaluate("42") }
}
