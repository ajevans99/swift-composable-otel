import ComposableOTel
import Foundation

private struct ConsumerValue: CustomStringConvertible {
  var description: String { "consumer-value" }
}

private struct ConsumerError: Error {}
private enum ConsumerIdentifierKind: TelemetryIdentifierKind {}

func publicInterpolationMustRemainUnavailable() {
  let bareString = "private"
  let customValue = ConsumerValue()
  let runtimeError = ConsumerError()
  let runtimeURL = URL(string: "https://example.test/private")!
  let consumerIdentifier = TelemetryIdentifier<ConsumerIdentifierKind>(
    validating: "consumer-value"
  )!

  _ = TelemetryLogMessage(stringLiteral: bareString)
  var interpolation = TelemetryLogMessage.StringInterpolation(
    literalCapacity: bareString.count,
    interpolationCount: 0
  )
  interpolation.appendLiteral(bareString)
  let _: TelemetryLogMessage = "\(bareString, privacy: .public)"
  let _: TelemetryLogMessage = "\(customValue, privacy: .public)"
  let _: TelemetryLogMessage = "\(runtimeError, privacy: .public)"
  let _: TelemetryLogMessage = "\(runtimeURL, privacy: .public)"
  let _: TelemetryLogMessage = "\(consumerIdentifier, privacy: .public)"
}

publicInterpolationMustRemainUnavailable()
