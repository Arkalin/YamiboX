import Foundation

enum YamiboRequestCancellationPolicy: Sendable {
    case propagateCancellation
    case completeStartedRequest
}

struct YamiboHTMLResponse: Sendable {
    let html: String
    let url: URL
    var file: ForumAttachmentFile? = nil
    var continuationURL: URL? = nil
}

struct YamiboClient: Sendable {
    var session: URLSession
    var credentials: YamiboRequestCredentials
    var userAgent: String
    var wafRecoverer: (any YamiboWAFChallengeRecovering)?
    var handlesCookies: Bool
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
        self.validateSession = validateSession
    }

    init(
        session: URLSession = YamiboNetworkConfiguration.makeSession(),
        credentials: YamiboRequestCredentials,
        wafRecoverer: (any YamiboWAFChallengeRecovering)? = nil,
        handlesCookies: Bool = true,
        validateSession: (@Sendable () async throws -> Void)? = nil
    ) {
        self.session = session
        self.credentials = credentials
        userAgent = credentials.userAgent
        self.wafRecoverer = wafRecoverer
        self.handlesCookies = handlesCookies
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

    /// Native documents use a task-scoped redirect guard. Unlike general forum
    /// reads, their URL is supplied by page links and form actions.
    func fetchPageDocument(url: URL, fields: [ForumFormValue]? = nil, files: [ForumFormFile] = [], referer: URL? = nil) async throws -> YamiboHTMLResponse {
        guard ForumWebPagePolicy.requiresForumHandling(url) else { throw ForumPageError.invalidURL }
        var request = YamiboNetworkConfiguration.makeRequest(url: ForumWebPagePolicy.secureURL(url), cachePolicy: .reloadIgnoringLocalCacheData)
        if let fields {
            request.httpMethod = "POST"
            if files.isEmpty {
                request.httpBody = formBody(fields.map { ($0.name, $0.value) })
                request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            } else {
                let boundary = "YamiboX-\(UUID().uuidString)"
                request.httpBody = ForumMultipart.body(fields: fields, files: files, boundary: boundary)
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            }
        }
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue(referer?.absoluteString, forHTTPHeaderField: "Referer")
        applyCredentials(credentials, to: &request, userAgent: userAgent)
        return try await performHTMLResponseRequest(
            request, userAgent: userAgent, cancellationPolicy: .propagateCancellation,
            delegate: ForumPageRedirectDelegate(), allowsFiles: true
        )
    }

    private func data(
        for request: URLRequest,
        cancellationPolicy: YamiboRequestCancellationPolicy,
        delegate: (any URLSessionTaskDelegate)? = nil
    ) async throws -> (Data, URLResponse) {
        switch cancellationPolicy {
        case .propagateCancellation:
            return try await session.data(for: request, delegate: delegate)
        case .completeStartedRequest:
            let requestTask = Task {
                try await session.data(for: request, delegate: delegate)
            }
            return try await requestTask.value
        }
    }

    private func performHTMLRequest(
        _ request: URLRequest,
        userAgent: String,
        cancellationPolicy: YamiboRequestCancellationPolicy
    ) async throws -> String {
        try await performHTMLResponseRequest(request, userAgent: userAgent, cancellationPolicy: cancellationPolicy).html
    }

    private func performHTMLResponseRequest(
        _ request: URLRequest,
        userAgent: String,
        cancellationPolicy: YamiboRequestCancellationPolicy,
        delegate: (any URLSessionTaskDelegate)? = nil,
        allowsFiles: Bool = false
    ) async throws -> YamiboHTMLResponse {
        do {
            try await validateSession?()
            let (initialData, response) = try await data(for: request, cancellationPolicy: cancellationPolicy, delegate: delegate)
            try await validateSession?()
            guard let httpResponse = response as? HTTPURLResponse else {
                throw YamiboError.invalidResponse(statusCode: nil)
            }

            guard YamiboWAFResponseDetector.matches(data: initialData, response: httpResponse, requestURL: request.url ?? YamiboDomain.baseURL) else {
                return try decodeResponse(data: initialData, response: httpResponse, allowsFiles: allowsFiles)
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

            if allowsFiles, request.httpMethod != "GET" || request.url.map(ForumWebPagePolicy.requiresConfirmationToLoad) == true {
                // Do not replay native account mutations or uploads after an
                // authentication round trip. The user must confirm a retry.
                throw YamiboError.securityVerificationRequired
            }

            var retry = request
            retry.cachePolicy = .reloadIgnoringLocalCacheData
            applyCredentials(refreshedCredentials, to: &retry, userAgent: userAgent)
            let (retryData, retryResponse) = try await data(for: retry, cancellationPolicy: cancellationPolicy, delegate: delegate)
            try await validateSession?()
            guard let retryHTTPResponse = retryResponse as? HTTPURLResponse else {
                throw YamiboError.invalidResponse(statusCode: nil)
            }
            if YamiboWAFResponseDetector.matches(data: retryData, response: retryHTTPResponse, requestURL: url) {
                await wafRecoverer.presentFallback(for: challenge)
                throw YamiboError.securityVerificationRequired
            }
            return try decodeResponse(data: retryData, response: retryHTTPResponse, allowsFiles: allowsFiles)
        } catch {
            throw LoadDiagnosticError.attaching(to: error, requestContext: request.url?.absoluteString)
        }
    }

    private func decodeResponse(data: Data, response: HTTPURLResponse, allowsFiles: Bool) throws -> YamiboHTMLResponse {
        if allowsFiles, [301, 302, 303, 307, 308].contains(response.statusCode),
           let location = response.value(forHTTPHeaderField: "Location"),
           let url = URL(string: location, relativeTo: response.url)?.absoluteURL,
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil {
            // Blocked redirects become explicit links, not silent requests with
            // credentials or automatic account actions.
            return YamiboHTMLResponse(html: "", url: response.url ?? YamiboDomain.baseURL, continuationURL: url)
        }
        let mime = response.mimeType?.lowercased() ?? "text/html"
        let prefix = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        let isHTML = mime.contains("html") || mime.contains("xml") || prefix.contains("<html") || prefix.contains("<!doctype html") || prefix.contains("<root")
        // Text responses from upload endpoints are numeric IDs / JSON, not
        // downloaded files. Attachments and plain-text documents carry a
        // disposition or a file URL, while image/PDF/binary MIME types suffice.
        let isFile = response.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true
            || mime.hasPrefix("image/") || mime.hasPrefix("audio/") || mime.hasPrefix("video/")
            || ["application/pdf", "application/octet-stream", "application/zip", "application/epub+zip"].contains(mime)
            || (mime == "text/plain" && response.url?.pathExtension.lowercased() == "txt")
        if allowsFiles, isFile, !isHTML {
            guard 200..<300 ~= response.statusCode else { throw YamiboError.invalidResponse(statusCode: response.statusCode) }
            guard data.count <= 50 * 1024 * 1024 else { throw ForumPageError.fileTooLarge }
            return YamiboHTMLResponse(
                html: "", url: response.url ?? YamiboDomain.baseURL,
                file: ForumAttachmentFile(name: response.suggestedFilename ?? "attachment", data: data)
            )
        }
        return YamiboHTMLResponse(html: try decodeHTML(from: data, response: response), url: response.url ?? YamiboDomain.baseURL)
    }

    private func applyCredentials(
        _ credentials: YamiboRequestCredentials,
        to request: inout URLRequest,
        userAgent: String
    ) {
        request.httpShouldHandleCookies = handlesCookies
        let cookieHeader = request.url.map { credentials.cookieHeader(for: $0) } ?? ""
        request.setValue(cookieHeader.isEmpty ? nil : cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    }

    private func decodeHTML(from data: Data, response: URLResponse) throws -> String {
        do {
            guard let httpResponse = response as? HTTPURLResponse else {
                throw YamiboError.invalidResponse(statusCode: nil)
            }
            guard 200 ..< 300 ~= httpResponse.statusCode else {
                if httpResponse.statusCode == 401 {
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
        } catch {
            throw LoadDiagnosticError.attaching(to: error, requestContext: response.url?.absoluteString, httpStatus: (response as? HTTPURLResponse)?.statusCode)
        }
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

final class ForumPageRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, ForumWebPagePolicy.isForumPage(url), url.scheme?.lowercased() == "https",
              !ForumWebPagePolicy.requiresConfirmationToLoad(url), request.httpMethod == "GET" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private extension CharacterSet {
    static let formURLQueryAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=%/?")
        return allowed
    }()
}
