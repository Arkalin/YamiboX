import Foundation

enum YamiboRequestCancellationPolicy: Sendable {
    case propagateCancellation
    case completeStartedRequest
}

struct YamiboClient: Sendable {
    var session: URLSession
    var cookie: String?
    var userAgent: String

    init(
        session: URLSession = YamiboNetworkConfiguration.makeSession(),
        cookie: String? = nil,
        userAgent: String = YamiboNetworkConfiguration.defaultMobileUserAgent
    ) {
        self.session = session
        self.cookie = cookie
        self.userAgent = userAgent
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
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        request.setValue(userAgent ?? self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        return try decodeHTML(from: data, response: response)
    }

    func fetchHTML(
        url: URL,
        userAgent: String? = nil,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        cancellationPolicy: YamiboRequestCancellationPolicy = .propagateCancellation
    ) async throws -> String {
        var request = YamiboNetworkConfiguration.makeRequest(url: url, cachePolicy: cachePolicy)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        request.setValue(userAgent ?? self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await data(for: request, cancellationPolicy: cancellationPolicy)
        return try decodeHTML(from: data, response: response)
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
