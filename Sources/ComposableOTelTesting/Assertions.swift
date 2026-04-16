import OpenTelemetrySdk

#if canImport(XCTest)
  import XCTest
#endif

// MARK: - Span assertions

extension InMemorySpanCollector {
  /// Assert that at least one span with the given name exists.
  ///
  /// Optionally checks that the span carries the specified string attributes.
  public func assertSpanExists(
    named name: String,
    withAttributes attributes: [String: String] = [:],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let matching = spans.filter { $0.name == name }

    guard !matching.isEmpty else {
      let available = spans.map(\.name)
      fail(
        "Expected span named '\(name)' but none found. Available: \(available)",
        file: file,
        line: line
      )
      return
    }

    if !attributes.isEmpty {
      let fullyMatching = matching.filter { span in
        attributes.allSatisfy { key, value in
          span.attributes[key]?.description == value
        }
      }
      if fullyMatching.isEmpty {
        fail(
          "Span '\(name)' exists but no match for attributes \(attributes). Found: \(matching.map { $0.attributes })",
          file: file,
          line: line
        )
      }
    }
  }

  /// Assert that no span with the given name exists.
  public func assertNoSpan(
    named name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let matching = spans.filter { $0.name == name }
    if !matching.isEmpty {
      fail(
        "Expected no span named '\(name)' but found \(matching.count)",
        file: file,
        line: line
      )
    }
  }

  /// Return all spans whose name matches.
  public func spans(named name: String) -> [SpanData] {
    spans.filter { $0.name == name }
  }
}

// MARK: - Metric assertions

extension InMemoryMetricReader {
  /// Assert that at least one metric with the given name has been recorded.
  public func assertMetricExists(
    named name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let matching = metrics.filter { $0.name == name }
    if matching.isEmpty {
      let available = metrics.map(\.name)
      fail(
        "Expected metric named '\(name)' but none found. Available: \(available)",
        file: file,
        line: line
      )
    }
  }

  /// Assert that no metric with the given name exists.
  public func assertNoMetric(
    named name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let matching = metrics.filter { $0.name == name }
    if !matching.isEmpty {
      fail(
        "Expected no metric named '\(name)' but found \(matching.count)",
        file: file,
        line: line
      )
    }
  }
}

// MARK: - Failure helper

/// Reports a test failure via XCTest when available, otherwise falls back to
/// `preconditionFailure`.
private func fail(
  _ message: String,
  file: StaticString,
  line: UInt
) {
  #if canImport(XCTest)
    XCTFail(message, file: file, line: line)
  #else
    preconditionFailure(message, file: file, line: line)
  #endif
}
