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
        try await html(YamiboNetworkConfiguration.makeRequest(url: route.url, cachePolicy: cachePolicy),
                       definition: route.requestDefinition, userAgent: userAgent, cancellationPolicy: cancellationPolicy)
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
        return try await html(request, definition: .write, userAgent: userAgent, cancellationPolicy: .propagateCancellation)
    }

    func fetchHTML(
        url: URL,
        userAgent: String? = nil,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        cancellationPolicy: YamiboRequestCancellationPolicy = .propagateCancellation
    ) async throws -> String {
        let request = YamiboNetworkConfiguration.makeRequest(url: url, cachePolicy: cachePolicy)
        return try await html(request, definition: .navigation(request), userAgent: userAgent, cancellationPolicy: cancellationPolicy)
    }

    private func html(_ request: URLRequest, definition: ForumRequestDefinition, userAgent: String?,
                      cancellationPolicy: YamiboRequestCancellationPolicy) async throws -> String {
        var request = request
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return try await perform(request, definition: definition, userAgent: userAgent,
                                 cancellationPolicy: cancellationPolicy, delegate: nil, bodyPolicy: nil).decodeHTML()
    }

    func performRequest(
        _ unsignedRequest: URLRequest,
        userAgent: String? = nil,
        cancellationPolicy: YamiboRequestCancellationPolicy = .propagateCancellation,
        delegate: (any URLSessionTaskDelegate)? = nil,
        bodyPolicy: NetworkResponseBodyPolicy? = nil
    ) async throws -> YamiboHTTPResponse {
        try await perform(unsignedRequest, definition: .navigation(unsignedRequest), userAgent: userAgent,
                          cancellationPolicy: cancellationPolicy, delegate: delegate, bodyPolicy: bodyPolicy)
    }

    private func perform(_ unsignedRequest: URLRequest, definition: ForumRequestDefinition, userAgent: String?,
                         cancellationPolicy: YamiboRequestCancellationPolicy, delegate: (any URLSessionTaskDelegate)?,
                         bodyPolicy: NetworkResponseBodyPolicy?) async throws -> YamiboHTTPResponse {
        let cookies = definition.credentials == .protectionOnly ? ForumWAFResult(cookies: credentials.cookies).cookies : credentials.cookies
        let context = requestContext.replacingCredentials(YamiboRequestCredentials(cookies: cookies, userAgent: userAgent ?? self.userAgent))
        do {
            return try await executor.execute(context: context, policy: definition.policy(for: unsignedRequest, lease: .init(duration: .seconds(40)),
                deliversCompletedInitialResponse: cancellationPolicy == .completeStartedRequest)) { attempt in
                try await validateSession?()
                try Task.checkCancellation()
                if definition.credentials == .protectionOnly,
                   unsignedRequest.url.map({ attempt.credentials.cookieHeader(for: $0).isEmpty }) != false {
                    throw RequestAdmissionError.missingProtectionState
                }
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

    private enum RequestAdmissionError: Error { case missingProtectionState }

    static func formBody(_ fields: [(String, String)]) -> Data? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=%/?")
        return fields.map { name, value in
            "\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").data(using: .utf8)
    }
}
