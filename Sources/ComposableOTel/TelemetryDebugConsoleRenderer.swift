#if DEBUG
  import Foundation

  /// An explicitly enabled, DEBUG-only sink for ephemeral private log rendering.
  ///
  /// The package invokes the sink synchronously and retains neither the rendered body nor any
  /// private interpolation. Do not retain the body in the supplied closure.
  public struct TelemetryDebugConsoleRenderer: Sendable {
    private let operation: @Sendable (TelemetryLogSeverity, String) -> Void

    public init(
      _ operation: @escaping @Sendable (TelemetryLogSeverity, String) -> Void
    ) {
      self.operation = operation
    }

    /// Prints one immediate local line without entering an OpenTelemetry pipeline.
    public static let standardOutput = Self { severity, body in
      print("[\(severity.rawValue.uppercased())] \(body)")
    }

    fileprivate func render(_ severity: TelemetryLogSeverity, body: String) {
      operation(severity, body)
    }
  }

  final class TelemetryDebugRenderBuffer: @unchecked Sendable {
    private(set) var body = ""
    private(set) var isValid = true

    func append(_ value: String) {
      guard isValid else { return }
      body += value
      if body.utf8.count > TelemetryLogMessage.maximumBodyUTF8Bytes {
        body.removeAll(keepingCapacity: false)
        isValid = false
      }
    }

    func discard() {
      body.removeAll(keepingCapacity: false)
      isValid = false
    }
  }

  enum TelemetryDebugRenderingContext {
    @TaskLocal static var buffer: TelemetryDebugRenderBuffer?
  }

  extension TelemetryClient {
    /// Records the normal redacted log and renders private values once to an immediate DEBUG sink.
    ///
    /// Only the ordinary redacted record may enter collectors, queues, exporters, OTLP, or
    /// persistence. This overload is absent from release builds.
    @discardableResult
    public func log(
      _ severity: TelemetryLogSeverity,
      _ message: @autoclosure () -> TelemetryLogMessage,
      debugConsole renderer: TelemetryDebugConsoleRenderer
    ) -> TelemetryLogRecordingResult {
      let buffer = TelemetryDebugRenderBuffer()
      defer { buffer.discard() }
      let message = TelemetryDebugRenderingContext.$buffer.withValue(buffer) {
        message()
      }
      if message.isValid, buffer.isValid {
        renderer.render(severity, body: buffer.body)
      }
      return log(severity, message)
    }
  }
#endif
