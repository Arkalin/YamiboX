import Foundation
import Testing
@testable import YamiboXCore

@Suite("Visible failure outcomes")
struct VisibleFailureOutcomeTests {
    @Test func updateCheckPreservesOriginalTransportError() async {
        let checker = AppUpdateChecker { _ in throw URLError(.timedOut) }
        let outcome = await checker.checkForUpdateWithDetails(currentBundleIdentifier: "example", currentVersion: "1")
        guard case .failure = outcome.result else { Issue.record("Expected failure"); return }
        #expect(outcome.details?.causes.first?.domain == NSURLErrorDomain)
        #expect(outcome.details?.causes.first?.code == URLError.timedOut.rawValue)
        #expect(!outcome.isCancelled)
    }

    @Test func cancelledUpdateCheckDoesNotProduceDiagnostics() async {
        let checker = AppUpdateChecker { _ in throw URLError(.cancelled) }
        let outcome = await checker.checkForUpdateWithDetails(currentBundleIdentifier: "example", currentVersion: "1")
        #expect(outcome.isCancelled)
        #expect(outcome.details == nil)
    }

    @Test func updateDecodeFailureIsNotMislabelledAsHTML() async {
        let checker = AppUpdateChecker { url in
            (Data("not-json".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let outcome = await checker.checkForUpdateWithDetails(currentBundleIdentifier: "example", currentVersion: "1")
        #expect(outcome.details?.causes.first?.type.contains("DecodingError") == true)
        #expect(outcome.details?.html == nil)
        #expect(outcome.details?.isHTMLParsingFailure == false)
    }

    @Test func recognizedActionRejectionDoesNotAttachResponseHTML() {
        do {
            let _: String = try LoadDiagnosticError.parsing(html: "<p>Permission denied</p>") {
                throw YamiboError.underlying("Permission denied")
            }
            Issue.record("Expected rejection")
        } catch {
            let details = LoadFailureDetails(error: error)
            #expect(details.html == nil)
            #expect(!details.isHTMLParsingFailure)
            #expect(details.summary == "Permission denied")
        }
    }

    @Test func aggregateCopiesEveryAttributedFailureAndRedactsTitles() {
        let first = LoadFailureDetails(error: URLError(.timedOut), requestContext: "first-request")
        let second = LoadFailureDetails(error: YamiboError.parsingFailed(context: "second-request"), html: "<p>source</p>")
        let details = LoadFailureDetails(message: "Two failures", failures: [
            .init(title: "First token=private-token", details: first), .init(title: "Second", details: second)
        ])
        #expect(details.copyText.contains("first-request"))
        #expect(details.copyText.contains("second-request"))
        #expect(details.copyText.contains("<p>source</p>"))
        #expect(!details.copyText.contains("private-token"))
    }
}
