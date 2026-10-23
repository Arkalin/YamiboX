import Foundation

enum YamiboRequestCancellationPolicy: Sendable {
    case propagateCancellation
    case completeStartedRequest
}

/// Construction and decoding only; the required executor owns every attempt.
struct YamiboClient: Sendable {
    var session: URLSession
    var credentials: YamiboRequestCredentials
    var userAgent: String
    let executor: ForumRequestExecutor
    let requestContext: ForumRequestContext
    var handlesCookies: Bool
    var cookieStorageContext: YamiboNetworkPolicy.CookieStorageContext
    var validateSession: (@Sendable () async throws -> Void)?

    var cookie: String? {
        let header = credentials.cookieHeader(for: YamiboDomain.baseURL)
        return header.isEmpty ? nil : header
    }

    init(
        session: URLSession = YamiboNetworkConfiguration.makeSession(),
        context: ForumRequestContext,
        executor: ForumRequestExecutor,
        handlesCookies: Bool = false,
        cookieStorageContext: YamiboNetworkPolicy.CookieStorageContext = .standard,
        validateSession: (@Sendable () async throws -> Void)? = nil
    ) {
        self.session = session
        credentials = context.credentials
        userAgent = context.credentials.userAgent
        requestContext = context
        self.executor = executor
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
        try await fetchHTML(url: route.url, replay: route.readReplayPolicy, userAgent: userAgent,
                            cachePolicy: cachePolicy, cancellationPolicy: cancellationPolicy)
    }

    func fetchThreadById(
        tid: String, authorID: String? = nil, reverse: Bool = false, page: Int = 1,
        userAgent: String? = nil, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        cancellationPolicy: YamiboRequestCancellationPolicy = .propagateCancellation
    ) async throws -> String {
        try await fetchHTML(for: .threadByID(tid: tid, page: page, authorID: authorID, reverse: reverse),
                            userAgent: userAgent, cachePolicy: cachePolicy, cancellationPolicy: cancellationPolicy)
    }

    func submitForm(for route: YamiboRoute, fields: [(String, String)], userAgent: String? = nil) async throws -> String {
        try await submitForm(url: route.url, fields: fields, userAgent: userAgent)
    }

    func submitForm(url: URL, fields: [(String, String)], userAgent: String? = nil) async throws -> String {
        var request = YamiboNetworkConfiguration.makeRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Self.formBody(fields)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        return try await html(request, replay: .never, userAgent: userAgent, cancellationPolicy: .propagateCancellation)
    }

    func fetchHTML(
        url: URL,
        replay: ForumReplayPolicy = .never,
        userAgent: String? = nil,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        cancellationPolicy: YamiboRequestCancellationPolicy = .propagateCancellation
    ) async throws -> String {
        try await html(YamiboNetworkConfiguration.makeRequest(url: url, cachePolicy: cachePolicy),
                       replay: replay, userAgent: userAgent, cancellationPolicy: cancellationPolicy)
    }

    private func html(_ request: URLRequest, replay: ForumReplayPolicy, userAgent: String?,
                      cancellationPolicy: YamiboRequestCancellationPolicy) async throws -> String {
        var request = request
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return try await performRequest(request, userAgent: userAgent, cancellationPolicy: cancellationPolicy, replay: replay).decodeHTML()
    }

    func performRequest(
        _ unsignedRequest: URLRequest,
        userAgent: String? = nil,
        cancellationPolicy: YamiboRequestCancellationPolicy = .propagateCancellation,
        delegate: (any URLSessionTaskDelegate)? = nil,
        replay: ForumReplayPolicy = .never,
        bodyPolicy: NetworkResponseBodyPolicy? = nil
    ) async throws -> YamiboHTTPResponse {
        let context = requestContext.replacingCredentials(YamiboRequestCredentials(cookies: credentials.cookies, userAgent: userAgent ?? self.userAgent))
        do {
            return try await executor.execute(context: context, policy: ForumRequestPolicy(replay: replay, lease: .init(duration: .seconds(40)),
                deliversCompletedInitialResponse: cancellationPolicy == .completeStartedRequest)) { attempt in
                try await validateSession?()
                try Task.checkCancellation()
                var request = unsignedRequest
                if attempt.number > 1 { request.cachePolicy = .reloadIgnoringLocalCacheData }
                YamiboNetworkPolicy.applyCredentials(attempt.credentials, to: &request,
                    handlesCookies: handlesCookies, cookieStorageContext: cookieStorageContext)
                let signedRequest = request
                let operation: @Sendable () async throws -> YamiboHTTPResponse = {
                    try await ForumDataTransport.data(request: signedRequest, attempt: attempt, session: session,
                                                      delegate: delegate, bodyPolicy: bodyPolicy)
                }
                let result: YamiboHTTPResponse
                switch cancellationPolicy {
                case .completeStartedRequest where attempt.number == 1:
                    result = try await Task { try await operation() }.value
                default:
                    result = try await operation()
                }
                try await validateSession?()
                return result
            }
        } catch {
            throw LoadDiagnosticError.attaching(to: error, requestContext: unsignedRequest.url?.absoluteString)
        }
    }

    static func formBody(_ fields: [(String, String)]) -> Data? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=%/?")
        return fields.map { name, value in
            "\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").data(using: .utf8)
    }
}
