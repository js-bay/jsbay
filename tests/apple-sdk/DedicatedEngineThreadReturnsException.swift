import JsBaySDK

func returnExceptionAcrossThreads(_ owner: DedicatedEngineThread) async throws -> JsException {
  try await owner.run { engine -> JsException in try engine.exception(engine.number(1)) }
}
