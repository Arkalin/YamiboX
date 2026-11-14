import Foundation

/// In-memory response bytes, never persisted or logged. Only controlled
/// transports may construct this after successfully receiving the entire body.
public struct ForumWAFChallengeDocument: Hashable, Sendable, CustomStringConvertible {
    public let url: URL
    public let body: Data
    public let mimeType: String
    public let textEncodingName: String?

    init?(response: HTTPURLResponse, completeBody: Data, request: URLRequest, attempt: ForumRequestAttempt) {
        guard Self.canReceive(response, request: request, attempt: attempt), let url = response.url,
              let mimeType = response.mimeType,
              !completeBody.isEmpty, completeBody.count <= ForumWAFResponseClassifier.maximumBodyBytes else { return nil }
        self.url = url
        body = completeBody
        self.mimeType = mimeType.lowercased()
        textEncodingName = response.textEncodingName
    }

    static func canReceive(_ response: HTTPURLResponse, request: URLRequest, attempt: ForumRequestAttempt) -> Bool {
        attempt.number == 1 && attempt.replay == .safeReadOnce
            && request.httpMethod == "GET" && request.httpBody == nil && request.httpBodyStream == nil
            && response.url == request.url
            && request.url.map { attempt.context.key.origin.contains($0) && !ForumWebPagePolicy.requiresConfirmationToLoad($0) } == true
            && ForumWAFResponseClassifier.mayContainChallenge(response)
            && ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "")
    }

    public var description: String { "ForumWAFChallengeDocument(bytes: \(body.count))" }
}
