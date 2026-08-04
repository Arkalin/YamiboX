import Foundation

enum YamiboRequestCancellationPolicy: Sendable {
    case propagateCancellation
    case completeStartedRequest
}

struct YamiboClient: Sendable {
    var session: URLSession
    var credentials: YamiboRequestCredentials
    var userAgent: String
    var wafRecoverer: (any YamiboWAFChallengeRecovering)?

    var cookie: String? {
        let header = credentials.cookieHeader(for: YamiboDomain.baseURL)
        return header.isEmpty ? nil : header
    }

    init(
        session: URLSession = YamiboNetworkConfiguration.makeSession(),
        cookie: String? = nil,
        userAgent: String = YamiboNetworkConfiguration.defaultMobileUserAgent,
        wafRecoverer: (any YamiboWAFChallengeRecovering)? = nil
    ) {
        self.session = session
        credentials = YamiboRequestCredentials(
            cookies: YamiboCookie.legacyCookies(from: cookie ?? ""),
            userAgent: userAgent
        )
        self.userAgent = userAgent
        self.wafRecoverer = wafRecoverer
    }

    init(
        session: URLSession = YamiboNetworkConfiguration.makeSession(),
        credentials: YamiboRequestCredentials,
        wafRecoverer: (any YamiboWAFChallengeRecovering)? = nil
    ) {
        self.session = session
        self.credentials = credentials
        userAgent = credentials.userAgent
        self.wafRecoverer = wafRecoverer
    }

    func fetchHTML(
        for route: YamiboRoute,
        userAgent: String? = nil,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        cancellationPolicy: YamiboRequestCancellationPolicy = .propagateCancellation
    ) async throws -> String {
        try await fetchHTML(
            url: route.url,
            userAgent: userAgent,
            cachePolicy: cachePolicy,
            cancellationPolicy: cancellationPolicy
        )
    }

    func fetchThreadById(
        tid: String,
        authorID: String? = nil,
        reverse: Bool = false,
        page: Int = 1,
        userAgent: String? = nil,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        cancellationPolicy: YamiboRequestCancellationPolicy = .propagateCancellation
    ) async throws -> String {
        try await fetchHTML(
            for: .threadByID(tid: tid, page: page, authorID: authorID, reverse: reverse),
            userAgent: userAgent,
            cachePolicy: cachePolicy,
            cancellationPolicy: cancellationPolicy
        )
    }

    func submitForm(
        for route: YamiboRoute,
        fields: [(String, String)],
        userAgent: String? = nil
    ) async throws -> String {
        try await submitForm(url: route.url, fields: fields, userAgent: userAgent)
    }

    func submitForm(
        url: URL,
        fields: [(String, String)],
        userAgent: String? = nil
    ) async throws -> String {
        var request = YamiboNetworkConfiguration.makeRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = formBody(fields)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let resolvedUserAgent = userAgent ?? self.userAgent
        applyCredentials(credentials, to: &request, userAgent: resolvedUserAgent)
        return try await performHTMLRequest(
            request,
            userAgent: resolvedUserAgent,
            cancellationPolicy: .propagateCancellation
        )
    }

    func fetchHTML(
        url: URL,
        userAgent: String? = nil,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        cancellationPolicy: YamiboRequestCancellationPolicy = .propagateCancellation
    ) async throws -> String {
        var request = YamiboNetworkConfiguration.makeRequest(url: url, cachePolicy: cachePolicy)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let resolvedUserAgent = userAgent ?? self.userAgent
        applyCredentials(credentials, to: &request, userAgent: resolvedUserAgent)
        return try await performHTMLRequest(
            request,
            userAgent: resolvedUserAgent,
            cancellationPolicy: cancellationPolicy
        )
    }

    private func data(
        for request: URLRequest,
        cancellationPolicy: YamiboRequestCancellationPolicy
    ) async throws -> (Data, URLResponse) {
        switch cancellationPolicy {
        case .propagateCancellation:
            return try await session.data(for: request)
        case .completeStartedRequest:
            let requestTask = Task {
                try await session.data(for: request)
            }
            return try await requestTask.value
        }
    }

    private func performHTMLRequest(
        _ request: URLRequest,
        userAgent: String,
        cancellationPolicy: YamiboRequestCancellationPolicy
    ) async throws -> String {
        let (initialData, response) = try await data(for: request, cancellationPolicy: cancellationPolicy)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw YamiboError.invalidResponse(statusCode: nil)
        }

        guard YamiboWAFResponseDetector.matches(data: initialData, response: httpResponse, requestURL: request.url ?? YamiboDomain.baseURL) else {
            return try decodeHTML(from: initialData, response: response)
        }

        guard let wafRecoverer, let url = request.url else {
            throw YamiboError.securityVerificationRequired
        }
        if cancellationPolicy == .propagateCancellation {
            try Task.checkCancellation()
        }

        let clearance = credentials.cookies.first {
            $0.name == "nox_jst_v1" && $0.matches(url)
        }
        let challenge = YamiboWAFChallenge(
            url: url,
            method: request.httpMethod ?? "GET",
            userAgent: userAgent,
            clearanceFingerprint: clearance.map { YamiboWAFChallenge.clearanceFingerprint(for: $0.value) },
            clearanceExpiresAt: clearance?.expiresAt
        )
        let refreshedCredentials: YamiboRequestCredentials
        do {
            refreshedCredentials = try await wafRecoverer.recover(from: challenge)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw YamiboError.securityVerificationRequired
        }

        var retry = request
        retry.cachePolicy = .reloadIgnoringLocalCacheData
        applyCredentials(refreshedCredentials, to: &retry, userAgent: userAgent)
        let (retryData, retryResponse) = try await data(for: retry, cancellationPolicy: cancellationPolicy)
        guard let retryHTTPResponse = retryResponse as? HTTPURLResponse else {
            throw YamiboError.invalidResponse(statusCode: nil)
        }
        if YamiboWAFResponseDetector.matches(data: retryData, response: retryHTTPResponse, requestURL: url) {
            await wafRecoverer.presentFallback(for: challenge)
            throw YamiboError.securityVerificationRequired
        }
        return try decodeHTML(from: retryData, response: retryResponse)
    }

    private func applyCredentials(
        _ credentials: YamiboRequestCredentials,
        to request: inout URLRequest,
        userAgent: String
    ) {
        let cookieHeader = request.url.map { credentials.cookieHeader(for: $0) } ?? ""
        request.setValue(cookieHeader.isEmpty ? nil : cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    }

    private func decodeHTML(from data: Data, response: URLResponse) throws -> String {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw YamiboError.invalidResponse(statusCode: nil)
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw YamiboError.notAuthenticated
            }
            throw YamiboError.invalidResponse(statusCode: httpResponse.statusCode)
        }

        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) else {
            throw YamiboError.unreadableBody
        }
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw YamiboError.emptyHTML
        }
        return html
    }

    private func formBody(_ fields: [(String, String)]) -> Data? {
        let body = fields
            .map { name, value in
                "\(percentEncode(name))=\(percentEncode(value))"
            }
            .joined(separator: "&")
        return body.data(using: .utf8)
    }

    private func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .formURLQueryAllowed) ?? value
    }
}

private extension CharacterSet {
    static let formURLQueryAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=%/?")
        return allowed
    }()
}
