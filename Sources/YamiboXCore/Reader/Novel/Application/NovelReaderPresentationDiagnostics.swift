import Foundation

package struct NovelReaderPresentationDiagnostics: Equatable, Sendable {
    package var structureBuildCount = 0
    package var positionUpdateCount = 0
    package var progressIndexBuildCount = 0
    package var attachedInformationBuildCount = 0
    package var pageCurlSequenceBuildCount = 0

    package init() {}
}

/// Opt-in timing; normal reading neither reads the clock nor emits per-update logs.
package enum NovelReaderPerformance {
    package static let isEnabled = ProcessInfo.processInfo.environment["YAMIBOX_READER_PERF"] == "1"

    package static func measure<T>(_ operation: String, _ work: () throws -> T) rethrows -> T {
        guard isEnabled else { return try work() }
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            YamiboLog.reader.info("Reader presentation \(operation, privacy: .public): \(milliseconds) ms")
        }
        return try work()
    }
}
