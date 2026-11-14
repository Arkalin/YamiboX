import Foundation

/// Shared credential handling for all forum transports. Provider-specific
/// evidence stays in the provider implementations, never in a feature workflow.
enum ForumProtectionState {
    static func ownsCookie(_ name: String) -> Bool {
        BaiduWAFProtocol.ownsCookie(name) || AliyunWAFProtocol.ownsCookie(name)
    }

    static func retainSessionCookies(from response: HTTPURLResponse, attempt: ForumRequestAttempt) async throws {
        guard let url = response.url, attempt.context.key.origin.contains(url) else { return }
        let cookies = AliyunWAFProtocol.sessionCookies(from: response)
        guard !cookies.isEmpty else { return }
        // The caller must supply a fresh network response, not cached Set-Cookie.
        try Task.checkCancellation()
        try await attempt.context.validate()
        do {
            try await attempt.context.commitWAFCookies(ForumWAFResult(cookies: cookies))
        } catch {
            try Task.checkCancellation()
            try await attempt.context.validate()
            YamiboLog.networking.warning("Forum protectionSession=persistenceFailed")
        }
        try await attempt.context.validate()
    }
}

/// Per-attempt response evidence. Delegate callbacks only record it; the
/// executor commits it after a successful transport and cancellation checks.
final class ForumResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private var networkResponse: HTTPURLResponse?

    func record(_ metrics: URLSessionTaskMetrics, origin: ForumOrigin) {
        guard let last = metrics.transactionMetrics.last, last.resourceFetchType == .networkLoad,
              metrics.transactionMetrics.allSatisfy({ transaction in
                  transaction.request.url.map(origin.contains) == true
                      && transaction.response?.url.map(origin.contains) == true
              }), let response = last.response as? HTTPURLResponse else { return }
        lock.withLock { networkResponse = response }
    }

    func commit(for attempt: ForumRequestAttempt) async throws {
        guard let response = lock.withLock({ networkResponse }) else { return }
        try await ForumProtectionState.retainSessionCookies(from: response, attempt: attempt)
    }
}
