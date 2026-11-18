import JsBaySDK

func returnEngineAcrossThreads(_ owner: DedicatedEngineThread) async throws -> Engine {
  try await owner.run { engine in engine }
}
