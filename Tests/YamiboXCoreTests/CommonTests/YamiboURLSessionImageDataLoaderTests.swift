import Foundation
import Testing
@testable import YamiboXCore

@Suite("Yamibo URLSession Image Data Loader", .serialized)
struct YamiboURLSessionImageDataLoaderTests {
    @Test func streamsChunksAndConcatenationMatchesOriginal() async throws {
        let url = makeStreamingStubURL()
        defer { ImageLoaderStreamingStubURLProtocol.reset(url) }
        let firstChunk = Data((0 ..< 96 * 1024).map { UInt8(truncatingIfNeeded: $0) })
        let secondChunk = Data((0 ..< 40 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        // `waitForSignal` holds the second chunk back until the first one has
        // been handed to `didReceiveData`, so the two deliveries can never be
        // coalesced into a single callback.
        ImageLoaderStreamingStubURLProtocol.setScript([
            .respond(statusCode: 200),
            .deliver(firstChunk),
            .waitForSignal,
            .deliver(secondChunk),
            .finish
        ], for: url)

        let outcome = await performStreamingLoad(url: url) {
            ImageLoaderStreamingStubURLProtocol.signal(url)
        }

        #expect(outcome.error == nil)
        #expect(outcome.chunks.count >= 2)
        #expect(outcome.chunks.reduce(Data(), +) == firstChunk + secondChunk)
        #expect(outcome.responses.allSatisfy { ($0 as? HTTPURLResponse)?.statusCode == 200 })
    }

    @Test func authFailureCompletesWithoutDeliveringData() async throws {
        let url = makeStreamingStubURL()
        defer { ImageLoaderStreamingStubURLProtocol.reset(url) }
        ImageLoaderStreamingStubURLProtocol.setScript([
            .respond(statusCode: 403),
            .deliver(Data([1, 2, 3])),
            .finish
        ], for: url)

        let outcome = await performStreamingLoad(url: url)

        #expect(outcome.error as? YamiboError == .notAuthenticated)
        #expect(outcome.chunks.isEmpty)
    }

    @Test func serverErrorCompletesWithoutDeliveringData() async throws {
        let url = makeStreamingStubURL()
        defer { ImageLoaderStreamingStubURLProtocol.reset(url) }
        ImageLoaderStreamingStubURLProtocol.setScript([
            .respond(statusCode: 500),
            .deliver(Data([9, 9])),
            .finish
        ], for: url)

        let outcome = await performStreamingLoad(url: url)

        #expect(outcome.error as? YamiboError == .invalidResponse(statusCode: 500))
        #expect(outcome.chunks.isEmpty)
    }

    @Test func midStreamFailureDeliversPartialDataBeforeMappedError() async throws {
        let url = makeStreamingStubURL()
        defer { ImageLoaderStreamingStubURLProtocol.reset(url) }
        let partial = Data(repeating: 0x5A, count: 48 * 1024)
        ImageLoaderStreamingStubURLProtocol.setScript([
            .respond(statusCode: 200),
            .deliver(partial),
            .waitForSignal,
            .fail(URLError(.networkConnectionLost))
        ], for: url)

        let outcome = await performStreamingLoad(url: url) {
            ImageLoaderStreamingStubURLProtocol.signal(url)
        }

        #expect(outcome.error as? YamiboError == .offline)
        #expect(!outcome.chunks.isEmpty)
        #expect(outcome.chunks.reduce(Data(), +) == partial)
    }

    @Test func connectionFailureBeforeResponseMapsToOffline() async throws {
        let url = makeStreamingStubURL()
        defer { ImageLoaderStreamingStubURLProtocol.reset(url) }
        ImageLoaderStreamingStubURLProtocol.setScript([
            .fail(URLError(.notConnectedToInternet))
        ], for: url)

        let outcome = await performStreamingLoad(url: url)

        #expect(outcome.error as? YamiboError == .offline)
        #expect(outcome.chunks.isEmpty)
    }
}

private struct StreamingLoadOutcome {
    var chunks: [Data]
    var responses: [URLResponse]
    var error: Error?
}

private func performStreamingLoad(
    url: URL,
    onChunk: @escaping @Sendable () -> Void = {}
) async -> StreamingLoadOutcome {
    let recorder = StreamingChunkRecorder(onChunk: onChunk)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ImageLoaderStreamingStubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let loader = YamiboURLSessionImageDataLoader(session: session)

    let error = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
        _ = loader.loadData(
            with: URLRequest(url: url),
            didReceiveData: { recorder.record($0, $1) },
            completion: { continuation.resume(returning: $0) }
        )
    }
    session.finishTasksAndInvalidate()
    return StreamingLoadOutcome(
        chunks: recorder.chunks,
        responses: recorder.responses,
        error: error
    )
}

private func makeStreamingStubURL() -> URL {
    URL(string: "https://img.example.com/streaming-loader-\(UUID().uuidString).jpg")!
}

private final class StreamingChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var chunksStorage: [Data] = []
    private var responsesStorage: [URLResponse] = []
    private let onChunk: @Sendable () -> Void

    init(onChunk: @escaping @Sendable () -> Void) {
        self.onChunk = onChunk
    }

    func record(_ data: Data, _ response: URLResponse) {
        lock.withLock {
            chunksStorage.append(data)
            responsesStorage.append(response)
        }
        onChunk()
    }

    var chunks: [Data] {
        lock.withLock { chunksStorage }
    }

    var responses: [URLResponse] {
        lock.withLock { responsesStorage }
    }
}

private final class ImageLoaderStreamingStubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Step: Sendable {
        case respond(statusCode: Int)
        case deliver(Data)
        case waitForSignal
        case fail(URLError)
        case finish
    }

    nonisolated(unsafe) private static var scriptsByURL: [URL: [Step]] = [:]
    nonisolated(unsafe) private static var signalsByURL: [URL: DispatchSemaphore] = [:]
    private static let lock = NSLock()

    static func setScript(_ steps: [Step], for url: URL) {
        lock.withLock {
            scriptsByURL[url] = steps
            signalsByURL[url] = DispatchSemaphore(value: 0)
        }
    }

    static func signal(_ url: URL) {
        let semaphore = lock.withLock { signalsByURL[url] }
        semaphore?.signal()
    }

    static func reset(_ url: URL) {
        let semaphore = lock.withLock { () -> DispatchSemaphore? in
            let semaphore = signalsByURL[url]
            scriptsByURL.removeValue(forKey: url)
            signalsByURL.removeValue(forKey: url)
            return semaphore
        }
        semaphore?.signal()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let script: (steps: [Step], semaphore: DispatchSemaphore)? = request.url.flatMap { url in
            Self.lock.withLock {
                guard
                    let steps = Self.scriptsByURL[url],
                    let semaphore = Self.signalsByURL[url]
                else {
                    return nil
                }
                return (steps, semaphore)
            }
        }
        guard let script, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        // Run the script off the protocol's own thread so `waitForSignal`
        // never stalls delivery of events that were already emitted.
        DispatchQueue.global().async { [self] in
            for step in script.steps {
                switch step {
                case .respond(let statusCode):
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: statusCode,
                        httpVersion: "HTTP/1.1",
                        headerFields: nil
                    )!
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                case .deliver(let data):
                    client?.urlProtocol(self, didLoad: data)
                case .waitForSignal:
                    _ = script.semaphore.wait(timeout: .now() + 10)
                case .fail(let error):
                    client?.urlProtocol(self, didFailWithError: error)
                    return
                case .finish:
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
            }
        }
    }

    override func stopLoading() {}
}
