import JsBaySDK

func returnErrorResultAcrossThreads(_ owner: DedicatedEngineThread) async throws -> Result<
  Double, Error
> {
  try await owner.run { engine -> Result<Double, Error> in
    return Result {
      let value = try engine.evaluate("throw new Error('failure')")
      defer { try? value.close() }
      return try value.number()
    }
  }
}
