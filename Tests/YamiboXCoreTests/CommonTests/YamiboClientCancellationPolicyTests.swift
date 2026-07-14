import Foundation
import Testing
@testable import YamiboXCore

@Suite(.serialized)
private struct YamiboClientCancellationPolicyTests {
    @Test func propagateCancellationCancelsInFlightHTMLRequest() async throws {
        let started = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        YamiboClientCancellationTestURLProtocol.configure(
            body: "<html><body>cancelled</body></html>",
            responseDelay: 0.25,
            started: started,
            stopped: stopped
        )
        defer { YamiboClientCancellationTestURLProtocol.reset() }

        let client = YamiboClient(session: makeYamiboClientCancellationTestSession())
        let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php"))
        let requestTask = Task {
            try await client.fetchHTML(url: url, cancellationPolicy: .propagateCancellation)
        }

        #expect(await waitForYamiboClientCancellationTestSignal(started))
        requestTask.cancel()

        do {
            _ = try await requestTask.value
            Issue.record("Expected the propagated cancellation request to fail.")
        } catch {}

        #expect(await waitForYamiboClientCancellationTestSignal(stopped))
    }

    @Test func completeStartedRequestFinishesAfterCallerCancellation() async throws {
        let started = DispatchSemaphore(value: 0)
        YamiboClientCancellationTestURLProtocol.configure(
            body: "<html><body>finished</body></html>",
            responseDelay: 0.25,
            started: started
        )
        defer { YamiboClientCancellationTestURLProtocol.reset() }

        let client = YamiboClient(session: makeYamiboClientCancellationTestSession())
        let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php"))
        let requestTask = Task {
            try await client.fetchHTML(url: url, cancellationPolicy: .completeStartedRequest)
        }

        #expect(await waitForYamiboClientCancellationTestSignal(started))
        requestTask.cancel()

        let html = try await requestTask.value
        #expect(html.contains("finished"))
    }

    @Test func completeStartedRequestStartsWhenCallerIsAlreadyCancelled() async throws {
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        YamiboClientCancellationTestURLProtocol.configure(
            body: "<html><body>started after cancellation</body></html>",
            responseDelay: 0.05,
            started: started
        )
        defer { YamiboClientCancellationTestURLProtocol.reset() }

        let client = YamiboClient(session: makeYamiboClientCancellationTestSession())
        let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php"))
        let requestTask = Task {
            _ = blockingWaitForYamiboClientCancellationTestSignal(gate)
            return try await client.fetchHTML(url: url, cancellationPolicy: .completeStartedRequest)
        }

        requestTask.cancel()
        gate.signal()

        let html = try await requestTask.value
        #expect(await waitForYamiboClientCancellationTestSignal(started))
        #expect(html.contains("started after cancellation"))
    }
}

private final class YamiboClientCancellationTestURLProtocol: URLProtocol {
    private struct Configuration {
        var body: String
        var responseDelay: TimeInterval
        var started: DispatchSemaphore?
        var stopped: DispatchSemaphore?
    }

    nonisolated(unsafe) private static var configuration: Configuration?

    private let lock = NSLock()
    private var isStopped = false

    static func configure(
        body: String,
        responseDelay: TimeInterval,
        started: DispatchSemaphore? = nil,
        stopped: DispatchSemaphore? = nil
    ) {
        configuration = Configuration(
            body: body,
            responseDelay: responseDelay,
            started: started,
            stopped: stopped
        )
    }

    static func reset() {
        configuration = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let configuration = Self.configuration else {
            client?.urlProtocol(self, didFailWithError: YamiboClientCancellationTestError.missingConfiguration)
            return
        }

        configuration.started?.signal()
        Thread.sleep(forTimeInterval: configuration.responseDelay)

        lock.lock()
        let shouldRespond = !isStopped
        lock.unlock()

        guard shouldRespond else { return }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(configuration.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        lock.lock()
        isStopped = true
        lock.unlock()
        Self.configuration?.stopped?.signal()
    }
}

private enum YamiboClientCancellationTestError: Error {
    case missingConfiguration
}

private func makeYamiboClientCancellationTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [YamiboClientCancellationTestURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func waitForYamiboClientCancellationTestSignal(_ semaphore: DispatchSemaphore) async -> Bool {
    await Task.detached {
        blockingWaitForYamiboClientCancellationTestSignal(semaphore)
    }.value
}

private func blockingWaitForYamiboClientCancellationTestSignal(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 2) == .success
}
