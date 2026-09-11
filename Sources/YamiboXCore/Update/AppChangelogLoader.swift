import Foundation

public struct AppChangelogLoader: Sendable {
    // Source identity stays stable for Debug builds and re-signed installations.
    public static let defaultBundleIdentifier = "com.arkalin.YamiboX"

    public enum Failure: Error, LocalizedError, Sendable {
        case sourceDoesNotContainCurrentApp

        public var errorDescription: String? {
            L10n.string("app_update.error.source_missing")
        }
    }

    private let fetchData: @Sendable (URL) async throws -> (Data, URLResponse)

    public init(session: URLSession = YamiboNetworkConfiguration.makeSession()) {
        fetchData = { url in
            var request = YamiboNetworkConfiguration.makeRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return try await session.data(for: request)
        }
    }

    init(fetchData: @escaping @Sendable (URL) async throws -> (Data, URLResponse)) {
        self.fetchData = fetchData
    }

    public func load(
        sourceURL: URL = AppUpdateChecker.defaultSourceURL,
        currentBundleIdentifier: String = Self.defaultBundleIdentifier
    ) async throws -> [AppSourceVersion] {
        do {
            let (data, response) = try await fetchData(sourceURL)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw AppUpdateCheckFailure.invalidResponse(statusCode: nil)
            }
            guard 200 ..< 300 ~= response.statusCode else {
                throw LoadDiagnosticError.attaching(
                    to: AppUpdateCheckFailure.invalidResponse(statusCode: response.statusCode),
                    httpStatus: response.statusCode
                )
            }
            guard !data.isEmpty else { throw AppUpdateCheckFailure.emptyBody }

            let source: AppSource
            do {
                source = try JSONDecoder().decode(AppSource.self, from: data)
            } catch {
                throw LoadDiagnosticError.mapping(
                    error, to: AppUpdateCheckFailure.decodingFailed(error.localizedDescription)
                )
            }
            guard let app = source.apps.first(where: { $0.bundleIdentifier == currentBundleIdentifier }) else {
                throw Failure.sourceDoesNotContainCurrentApp
            }
            // The source defines the display order, just as it defines the latest update.
            return app.versions
        } catch {
            throw LoadDiagnosticError.attaching(to: error, requestContext: sourceURL.absoluteString)
        }
    }
}
