import Foundation

struct ForumPageResponse: Sendable {
    let html: String
    let url: URL
    var file: ForumAttachmentFile? = nil
    var continuationURL: URL? = nil
}

/// Adapts native forum documents to the shared authenticated HTTP transport.
/// Form encoding, attachment classification and action safety belong to Forum.
struct ForumPageClient: Sendable {
    let transport: YamiboClient

    func fetchDocument(
        url: URL,
        fields: [ForumFormValue]? = nil,
        files: [ForumFormFile] = [],
        referer: URL? = nil,
        downloadProgress: (@Sendable (DownloadTransferProgress) -> Void)? = nil
    ) async throws -> ForumPageResponse {
        guard ForumWebPagePolicy.requiresForumHandling(url) else { throw ForumPageError.invalidURL }
        var request = YamiboNetworkConfiguration.makeRequest(url: documentURL(url), cachePolicy: .reloadIgnoringLocalCacheData)
        if let fields {
            request.httpMethod = "POST"
            if files.isEmpty {
                request.httpBody = YamiboClient.formBody(fields.map { ($0.name, $0.value) })
                request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            } else {
                let boundary = "YamiboX-\(UUID().uuidString)"
                request.httpBody = ForumMultipart.body(fields: fields, files: files, boundary: boundary)
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            }
        }
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue(referer?.absoluteString, forHTTPHeaderField: "Referer")
        // Discuz can mutate state with GET links as well as form submissions.
        // Recovery may complete, but neither kind of action may be replayed.
        let allowsWAFReplay = request.httpMethod == "GET"
            && request.url.map(ForumWebPagePolicy.requiresConfirmationToLoad) != true
        let delegate = ForumPageRedirectDelegate(progress: downloadProgress)
        defer { delegate.stopObserving() }
        do {
            let response = try await transport.performRequest(
                request,
                delegate: delegate,
                allowsWAFReplay: allowsWAFReplay
            )
            return try decode(response)
        } catch {
            throw LoadDiagnosticError.attaching(to: error, requestContext: request.url?.absoluteString)
        }
    }

    private func documentURL(_ url: URL) -> URL {
        let secured = ForumWebPagePolicy.secureURL(url)
        guard ForumPagePurpose(url: secured) == .blogEditor,
              var components = URLComponents(url: secured, resolvingAgainstBaseURL: false) else { return secured }
        // The touch blog form omits privacy controls and upload configuration.
        // Ask for the complete form without changing the authenticated User-Agent.
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "mobile" }
        items.append(.init(name: "mobile", value: "no"))
        components.queryItems = items
        return components.url ?? secured
    }

    private func decode(_ result: YamiboHTTPResponse) throws -> ForumPageResponse {
        let data = result.data
        let response = result.response
        if [301, 302, 303, 307, 308].contains(response.statusCode),
           let location = response.value(forHTTPHeaderField: "Location"),
           let url = URL(string: location, relativeTo: response.url)?.absoluteURL,
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil {
            // Blocked redirects become explicit links, not silent requests with
            // credentials or automatic account actions.
            return ForumPageResponse(html: "", url: response.url ?? YamiboDomain.baseURL, continuationURL: url)
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
        if isFile, !isHTML {
            guard 200..<300 ~= response.statusCode else { throw YamiboError.invalidResponse(statusCode: response.statusCode) }
            guard data.count <= 50 * 1024 * 1024 else { throw ForumPageError.fileTooLarge }
            return ForumPageResponse(
                html: "", url: response.url ?? YamiboDomain.baseURL,
                file: ForumAttachmentFile(name: response.suggestedFilename ?? "attachment", data: data)
            )
        }
        return ForumPageResponse(html: try result.decodeHTML(), url: response.url ?? YamiboDomain.baseURL)
    }
}

private final class ForumPageRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: (@Sendable (DownloadTransferProgress) -> Void)?
    private let lock = NSLock()
    private var currentTask: ObjectIdentifier?
    private var observations: [NSKeyValueObservation] = []

    init(progress: (@Sendable (DownloadTransferProgress) -> Void)?) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        guard progress != nil else { return }
        // WAF recovery creates a new task. Discard the previous attempt's
        // observers and bytes rather than counting both responses as one file.
        stopObserving()
        lock.withLock { currentTask = ObjectIdentifier(task) }
        let received = task.observe(\.countOfBytesReceived) { [weak self] task, _ in
            self?.report(task)
        }
        let expected = task.observe(\.countOfBytesExpectedToReceive) { [weak self] task, _ in
            self?.report(task)
        }
        lock.withLock { observations = [received, expected] }
        report(task)
    }

    private func report(_ task: URLSessionTask) {
        lock.withLock {
            guard currentTask == ObjectIdentifier(task) else { return }
            progress?(DownloadTransferProgress(
                receivedBytes: max(0, task.countOfBytesReceived),
                expectedBytes: task.countOfBytesExpectedToReceive
            ))
        }
    }

    func stopObserving() {
        let retired = lock.withLock {
            currentTask = nil
            let retired = observations
            observations = []
            return retired
        }
        retired.forEach { $0.invalidate() }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let redirected = YamiboNetworkPolicy.redirectedRequest(request, from: task.originalRequest?.url),
              let url = redirected.url, ForumWebPagePolicy.isForumPage(url),
              url.scheme?.lowercased() == YamiboForumEnvironment.current.baseURL.scheme,
              !ForumWebPagePolicy.requiresConfirmationToLoad(url), redirected.httpMethod == "GET" else {
            completionHandler(nil)
            return
        }
        completionHandler(redirected)
    }
}
