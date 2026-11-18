import Foundation
import JsBaySDK

struct ResultSnapshot: EngineThreadResult {
  let values: [Double?]
}

func checkThreadResults(_ owner: DedicatedEngineThread) async throws {
  try owner.performOnOwner { _ in }
  try await owner.perform { _ in }

  let scalar = try owner.runOnOwner { _ in 42 }
  let asynchronousScalar = try await owner.run { _ in 42.0 }
  let snapshot = try owner.runOnOwner { engine in
    do {
      _ = try engine.evaluate("throw new Error('safe')")
      throw DedicatedEngineThreadError.closed
    } catch let error as JsException {
      return try error.detailsAndClose()
    }
  }
  let dto = try await owner.run { _ in ResultSnapshot(values: [42, nil]) }
  let typedResult = try owner.runOnOwner { _ in
    Result<Double, DedicatedEngineThreadError>.success(42)
  }
  precondition(scalar == 42 && asynchronousScalar == 42 && snapshot.message == "safe")
  let typedValue = try typedResult.get()
  precondition(dto.values == [42, nil] && typedValue == 42)
}
