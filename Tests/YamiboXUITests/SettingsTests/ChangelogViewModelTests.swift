import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class ChangelogViewModelTests: XCTestCase {
    func testLoadsCompleteHistory() async {
        let versions = [AppSourceVersion(
            version: "1.0", localizedDescription: "First line\nSecond line",
            downloadURL: URL(string: "https://example.com/app.ipa")!
        )]
        let model = ChangelogViewModel(loadVersions: { versions })

        await model.load()

        guard case let .loaded(loaded) = model.state else {
            return XCTFail("Expected loaded history")
        }
        XCTAssertEqual(loaded, versions)
    }

    func testEmptyHistoryLoadsSuccessfully() async {
        let model = ChangelogViewModel(loadVersions: { [] })

        await model.load()

        guard case let .loaded(versions) = model.state else {
            return XCTFail("Expected empty history")
        }
        XCTAssertTrue(versions.isEmpty)
    }

    func testFailureCanBeRetried() async {
        let loader = RetryLoader()
        let model = ChangelogViewModel(loadVersions: { try await loader.load() })

        await model.load()

        guard case let .failed(details) = model.state else {
            return XCTFail("Expected failure")
        }
        XCTAssertFalse(details.summary.isEmpty)

        await model.load()

        guard case .loaded = model.state else {
            return XCTFail("Expected successful retry")
        }
    }

    func testCancellationDoesNotShowFailureAndAllowsReload() async {
        let loader = RetryLoader(error: URLError(.cancelled))
        let model = ChangelogViewModel(loadVersions: { try await loader.load() })

        await model.load()

        guard case .idle = model.state else {
            return XCTFail("Expected idle state after cancellation")
        }

        await model.load()

        guard case .loaded = model.state else {
            return XCTFail("Expected successful reload")
        }
    }
}

private actor RetryLoader {
    private var attempts = 0
    private let error: URLError

    init(error: URLError = URLError(.notConnectedToInternet)) {
        self.error = error
    }

    func load() throws -> [AppSourceVersion] {
        attempts += 1
        if attempts == 1 { throw error }
        return []
    }
}
