import Foundation
import Testing
@testable import YamiboXCore

@Suite struct ForumComposerPerformanceTests {
    @Test @MainActor func longDocumentParseAndIncrementalEditingStayWithinBudget() throws {
        let block = "[collapse=1,title][b]body[/b][/collapse]\n"
        let seed = String(repeating: "paragraph text 中文\n" + block, count: 200)
        let source = seed + String(repeating: "x", count: 100_000 - seed.utf16.count)
        #expect(source.utf16.count == 100_000)
        let clock = ContinuousClock()
        let start = clock.now
        var document = ForumComposerDocument(source: source)
        var projection = ForumComposerProjection(document: document)
        let cold = milliseconds(start.duration(to: clock.now))
        #expect(projection.spans.filter { $0.kind == .atomic }.count == 200)
        var timings: [Double] = []
        var commands: [Double] = []
        var projections: [Double] = []
        for _ in 0..<50 {
            let start = clock.now
            try document.apply(.typeVisible(.init(location: 5), "a", enabled: [:], disabled: []))
            let commandEnd = clock.now
            projection = ForumComposerProjection(document: document)
            timings.append(milliseconds(start.duration(to: clock.now)))
            commands.append(milliseconds(start.duration(to: commandEnd)))
            projections.append(milliseconds(commandEnd.duration(to: clock.now)))
        }
        let p95 = timings.sorted()[47]
        print("BBCode benchmark: UTF16=100000 complex=200 cold_ms=\(cold) edit_p95_ms=\(p95)")
        print("BBCode timing details: command_median_ms=\(commands.sorted()[25]) projection_median_ms=\(projections.sorted()[25]) command_p95_ms=\(commands.sorted()[47]) projection_p95_ms=\(projections.sorted()[47])")
        #expect(cold <= 500)
        // The latency gate runs in Release, without debug/coverage instrumentation.
        #if !DEBUG
        #expect(p95 <= 50)
        #endif
        #expect(document.source.utf16.count == 100_050)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
