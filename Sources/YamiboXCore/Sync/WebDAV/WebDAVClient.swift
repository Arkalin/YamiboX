import Foundation

struct WebDAVRemoteFile: Sendable {
    var data: Data
    var etag: String?
}

enum WebDAVWriteCondition: Sendable {
    case absent
    case matches(String)
}

struct WebDAVClient: Sendable {
    let session: URLSession

    init(session: URLSession = YamiboNetworkConfiguration.makeSession()) {
        self.session = session
    }

    func fetchPayload(settings: WebDAVSyncSettings, fileName: String) async throws -> WebDAVRemoteFile {
        let config = try configuration(from: settings, fileName: fileName)
        var request = YamiboNetworkConfiguration.makeRequest(url: config.fileURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        applyHeaders(to: &request, configuration: config)

        let (data, response) = try await session.data(for: request)
        let statusCode = try statusCode(from: response)
        guard statusCode != 404 else { throw WebDAVSyncError.notFound }
        guard statusCode != 401 && statusCode != 403 else { throw WebDAVSyncError.notAuthenticated }
        guard 200 ..< 300 ~= statusCode else { throw WebDAVSyncError.invalidResponse(statusCode) }
        guard !data.isEmpty else { throw WebDAVSyncError.emptyPayload }
        return WebDAVRemoteFile(data: data, etag: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"))
    }

    /// Ensures the remote sync directory exists. Callers batch this to once
    /// per sync round rather than once per uploaded dataset.
    func ensureDirectoryExists(settings: WebDAVSyncSettings) async throws {
        let config = try configuration(from: settings, fileName: "")
        try await createDirectoryIfNeeded(configuration: config)
    }

    func uploadPayloadData(_ data: Data, settings: WebDAVSyncSettings, fileName: String, condition: WebDAVWriteCondition) async throws {
        let config = try configuration(from: settings, fileName: fileName)

        var request = YamiboNetworkConfiguration.makeRequest(url: config.fileURL)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        switch condition {
        case .absent:
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        case let .matches(etag):
            guard Self.isStrongETag(etag) else { throw WebDAVSyncError.unsafeConditionalWrite }
            request.setValue(etag, forHTTPHeaderField: "If-Match")
        }
        applyHeaders(to: &request, configuration: config)

        let (_, response) = try await session.data(for: request)
        let statusCode = try statusCode(from: response)
        guard statusCode != 412 else { throw WebDAVSyncError.writeConflict }
        guard statusCode != 401 && statusCode != 403 else { throw WebDAVSyncError.notAuthenticated }
        guard 200 ..< 300 ~= statusCode else { throw WebDAVSyncError.invalidResponse(statusCode) }
    }

    static func isStrongETag(_ etag: String) -> Bool {
        etag.count >= 2 && etag.hasPrefix("\"") && etag.hasSuffix("\"") && !etag.contains("\r") && !etag.contains("\n")
    }

    /// A strong validator alone does not prove the server enforces it. Probe
    /// a unique disposable resource, never an existing user dataset.
    func verifyConditionalWrites(settings: WebDAVSyncSettings) async throws {
        let name = ".yamibox-sync-probe-\(UUID().uuidString).json"
        do {
            let first = Data("{\"probe\":1}".utf8)
            let second = Data("{\"probe\":2}".utf8)
            try await uploadPayloadData(first, settings: settings, fileName: name, condition: .absent)
            let initial = try await fetchPayload(settings: settings, fileName: name)
            guard initial.data == first, let etag = initial.etag, Self.isStrongETag(etag) else {
                throw WebDAVSyncError.unsafeConditionalWrite
            }
            try await expectConflict(second, settings: settings, name: name, condition: .absent)
            try await expectConflict(second, settings: settings, name: name, condition: .matches("\"missing-\(UUID().uuidString)\""))
            try await uploadPayloadData(second, settings: settings, fileName: name, condition: .matches(etag))
            let updated = try await fetchPayload(settings: settings, fileName: name)
            guard updated.data == second, let nextETag = updated.etag,
                  Self.isStrongETag(nextETag), nextETag != etag else {
                throw WebDAVSyncError.unsafeConditionalWrite
            }
            try await expectConflict(first, settings: settings, name: name, condition: .matches(etag))
            guard try await fetchPayload(settings: settings, fileName: name).data == second else {
                throw WebDAVSyncError.unsafeConditionalWrite
            }
        } catch {
            // Cleanup must outlive cancellation of the sync that created it.
            await cleanupProbe(name, settings: settings)
            throw error
        }
        try await Task.detached { try await removeProbe(name, settings: settings) }.value
    }

    private func expectConflict(_ data: Data, settings: WebDAVSyncSettings, name: String, condition: WebDAVWriteCondition) async throws {
        do {
            try await uploadPayloadData(data, settings: settings, fileName: name, condition: condition)
        } catch WebDAVSyncError.writeConflict {
            return
        }
        throw WebDAVSyncError.unsafeConditionalWrite
    }

    private func cleanupProbe(_ name: String, settings: WebDAVSyncSettings) async {
        await Task.detached {
            do { try await removeProbe(name, settings: settings) }
            catch { YamiboLog.sync.warning("Unable to remove WebDAV capability probe \(name): \(error)") }
        }.value
    }

    private func removeProbe(_ name: String, settings: WebDAVSyncSettings) async throws {
        let config = try configuration(from: settings, fileName: name)
        var request = YamiboNetworkConfiguration.makeRequest(url: config.fileURL)
        request.httpMethod = "DELETE"
        applyHeaders(to: &request, configuration: config)
        let (_, response) = try await session.data(for: request)
        let status = try statusCode(from: response)
        guard status == 404 || 200 ..< 300 ~= status else { throw WebDAVSyncError.invalidResponse(status) }
    }

    private func createDirectoryIfNeeded(configuration: Configuration) async throws {
        var request = YamiboNetworkConfiguration.makeRequest(url: configuration.directoryURL)
        request.httpMethod = "MKCOL"
        applyHeaders(to: &request, configuration: configuration)

        let (_, response) = try await session.data(for: request)
        let statusCode = try statusCode(from: response)
        guard statusCode != 401 && statusCode != 403 else { throw WebDAVSyncError.notAuthenticated }
        guard 200 ..< 300 ~= statusCode || statusCode == 405 else {
            throw WebDAVSyncError.invalidResponse(statusCode)
        }
    }

    private func configuration(from settings: WebDAVSyncSettings, fileName: String) throws -> Configuration {
        guard
            let baseURL = URL(string: settings.trimmedBaseURLString),
            !settings.trimmedUsername.isEmpty
        else {
            throw WebDAVSyncError.invalidConfiguration
        }

        let directoryURL = baseURL.appendingPathComponent("YamiboX", isDirectory: true)
        return Configuration(
            directoryURL: directoryURL,
            fileURL: directoryURL.appendingPathComponent(fileName, isDirectory: false),
            username: settings.trimmedUsername,
            password: settings.password
        )
    }

    private func applyHeaders(to request: inout URLRequest, configuration: Configuration) {
        let token = Data("\(configuration.username):\(configuration.password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func statusCode(from response: URLResponse) throws -> Int {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVSyncError.invalidResponse(nil)
        }
        return httpResponse.statusCode
    }

    private struct Configuration: Sendable {
        var directoryURL: URL
        var fileURL: URL
        var username: String
        var password: String
    }
}
