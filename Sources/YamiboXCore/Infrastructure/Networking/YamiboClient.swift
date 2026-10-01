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
    var handlesCookies: Bool
    var cookieStorageContext: YamiboNetworkPolicy.CookieStorageContext
    var validateSession: (@Sendable () async throws -> Void)?

    var cookie: String? {
        let header = credentials.cookieHeader(for: YamiboDomain.baseURL)
        return header.isEmpty ? nil : header
    }

    init(
        session: URLSession = YamiboNetworkConfiguration.makeSession(),
        cookie: String? = nil,
        userAgent: String = YamiboNetworkConfiguration.defaultMobileUserAgent,
        wafRecoverer: (any YamiboWAFChallengeRecovering)? = nil,
        handlesCookies: Bool = true,
        cookieStorageContext: YamiboNetworkPolicy.CookieStorageContext = .standard,
        validateSession: (@Sendable () async throws -> Void)? = nil
    ) {
        self.session = session
        credentials = YamiboRequestCredentials(
            cookies: YamiboCookie.legacyCookies(from: cookie ?? ""),
            userAgent: userAgent
        )
        self.userAgent = userAgent
        self.wafRecoverer = wafRecoverer
        self.handlesCookies = handlesCookies
        self.cookieStorageContext = cookieStorageContext
        self.validateSession = validateSession
    }

    init(
        session: URLSession = YamiboNetworkConfiguration.makeSession(),
        credentials: YamiboRequestCredentials,
        wafRecoverer: (any YamiboWAFChallengeRecovering)? = nil,
        handlesCookies: Bool = true,
        cookieStorageContext: YamiboNetworkPolicy.CookieStorageContext = .standard,
        validateSession: (@Sendable () async throws -> Void)? = nil
    ) {
        self.session = session
        self.credentials = credentials
        userAgent = credentials.userAgent
        self.wafRecoverer = wafRecoverer
        self.handlesCookies = handlesCookies
        self.cookieStorageContext = cookieStorageContext
        self.validateSession = validateSession
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
        request.httpBody = Self.formBody(fields)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let resolvedUserAgent = userAgent ?? self.userAgent
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
        return try await performHTMLRequest(
            request,
            userAgent: resolvedUserAgent,
            cancellationPolicy: cancellationPolicy
        )
    }

    private func data(
        for request: URLRequest,
        cancellationPolicy: YamiboRequestCancellationPolicy,
        delegate: (any URLSessionTaskDelegate)? = nil,
        bodyPolicy: NetworkResponseBodyPolicy? = nil
    ) async throws -> (Data, URLResponse) {
        switch cancellationPolicy {
        case .propagateCancellation:
            return try await NetworkLoggedTransport.data(for: request, using: session, delegate: delegate, bodyPolicy: bodyPolicy)
        case .completeStartedRequest:
            let requestTask = Task {
                try await NetworkLoggedTransport.data(for: request, using: session, delegate: delegate, bodyPolicy: bodyPolicy)
            }
            return try await requestTask.value
        }
    }

    private func performHTMLRequest(
        _ request: URLRequest,
        userAgent: String,
        cancellationPolicy: YamiboRequestCancellationPolicy
    ) async throws -> String {
        do {
            return try await performRequest(request, userAgent: userAgent, cancellationPolicy: cancellationPolicy).decodeHTML()
        } catch {
            throw LoadDiagnosticError.attaching(to: error, requestContext: request.url?.absoluteString)
        }
    }

    /// Applies authentication and WAF recovery without interpreting feature payloads.
    /// Callers own redirect admission, replay safety and HTTP body classification.
    func performRequest(
        _ unsignedRequest: URLRequest,
        userAgent: String? = nil,
        cancellationPolicy: YamiboRequestCancellationPolicy = .propagateCancellation,
        delegate: (any URLSessionTaskDelegate)? = nil,
        allowsWAFReplay: Bool = true,
        bodyPolicy: NetworkResponseBodyPolicy? = nil
    ) async throws -> YamiboHTTPResponse {
        let userAgent = userAgent ?? self.userAgent
        var request = unsignedRequest
        applyCredentials(credentials, to: &request, userAgent: userAgent)
        do {
            try await validateSession?()
            let (initialData, response) = try await data(for: request, cancellationPolicy: cancellationPolicy, delegate: delegate, bodyPolicy: bodyPolicy)
            try await validateSession?()
            guard let httpResponse = response as? HTTPURLResponse else {
                throw YamiboError.invalidResponse(statusCode: nil)
            }

            guard YamiboWAFResponseDetector.matches(data: initialData, response: httpResponse, requestURL: request.url ?? YamiboDomain.baseURL) else {
                return YamiboHTTPResponse(data: initialData, response: httpResponse)
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
                let recovered = try await wafRecoverer.recover(from: challenge)
                try await validateSession?()
                // A WAF retry may refresh clearance, never the request's forum identity.
                refreshedCredentials = YamiboRequestCredentials(
                    cookies: credentials.cookies.filter { !YamiboCookie.isWAFCookie($0.name) }
                        + recovered.cookies.filter { YamiboCookie.isWAFCookie($0.name) },
                    userAgent: userAgent
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw LoadDiagnosticError.mapping(error, to: YamiboError.securityVerificationRequired)
            }

            if !allowsWAFReplay {
                // Recovery may complete, but replay still requires caller approval.
                throw YamiboError.securityVerificationRequired
            }

            var retry = request
            retry.cachePolicy = .reloadIgnoringLocalCacheData
            applyCredentials(refreshedCredentials, to: &retry, userAgent: userAgent)
            let (retryData, retryResponse) = try await data(for: retry, cancellationPolicy: cancellationPolicy, delegate: delegate, bodyPolicy: bodyPolicy)
            try await validateSession?()
            guard let retryHTTPResponse = retryResponse as? HTTPURLResponse else {
                throw YamiboError.invalidResponse(statusCode: nil)
            }
            if YamiboWAFResponseDetector.matches(data: retryData, response: retryHTTPResponse, requestURL: url) {
                await wafRecoverer.presentFallback(for: challenge)
                throw YamiboError.securityVerificationRequired
            }
            return YamiboHTTPResponse(data: retryData, response: retryHTTPResponse)
        } catch {
            throw LoadDiagnosticError.attaching(to: error, requestContext: request.url?.absoluteString)
        }
    }

    private func applyCredentials(
        _ credentials: YamiboRequestCredentials,
        to request: inout URLRequest,
        userAgent: String
    ) {
        YamiboNetworkPolicy.applyCredentials(
            credentials, to: &request, userAgent: userAgent,
            handlesCookies: handlesCookies, cookieStorageContext: cookieStorageContext
        )
    }

    static func formBody(_ fields: [(String, String)]) -> Data? {
        let body = fields
            .map { name, value in
                "\(percentEncode(name))=\(percentEncode(value))"
            }
            .joined(separator: "&")
        return body.data(using: .utf8)
    }

    private static func percentEncode(_ value: String) -> String {
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
