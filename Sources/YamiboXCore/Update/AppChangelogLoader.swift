import Foundation

public struct AppChangelogLoader: Sendable {
    public static let defaultBundleIdentifier = "com.arkalin.YamiboX"

    public enum Failure: Error, LocalizedError, Sendable {
        case sourceDoesNotContainCurrentApp

        public var errorDescription: String? {
            L10n.string("app_update.error.source_missing")
        }
    }

    private let sourceLoader: AppSourceLoader

    public init(session: URLSession = YamiboNetworkConfiguration.makeSession()) {
        sourceLoader = AppSourceLoader(session: session)
    }

    init(fetchData: @escaping @Sendable (URL) async throws -> (Data, URLResponse)) {
        sourceLoader = AppSourceLoader(fetchData: fetchData)
    }

    public func load(
        sourceURL: URL = AppUpdateChecker.defaultSourceURL,
        currentBundleIdentifier: String = Self.defaultBundleIdentifier
    ) async throws -> [AppSourceVersion] {
        do {
            let (data, response) = try await sourceLoader.fetch(sourceURL: sourceURL)
            try Task.checkCancellation()
            let source: AppSource
            do {
                source = try AppSourceLoader.decode(data: data, response: response)
            } catch let failure as AppSourceLoader.Failure {
                throw Self.map(failure)
            }
            guard let app = source.apps.first(where: { $0.bundleIdentifier == currentBundleIdentifier }) else {
                throw Failure.sourceDoesNotContainCurrentApp
            }
            return app.versions
        } catch {
            throw LoadDiagnosticError.attaching(to: error, requestContext: sourceURL.absoluteString)
        }
    }

    private static func map(_ failure: AppSourceLoader.Failure) -> any Error {
        switch failure {
        case let .invalidResponse(statusCode, _):
            let error = AppUpdateCheckFailure.invalidResponse(statusCode: statusCode)
            guard let statusCode else { return error }
            return LoadDiagnosticError.attaching(to: error, httpStatus: statusCode)
        case .emptyBody:
            return AppUpdateCheckFailure.emptyBody
        case let .decodingFailed(underlying, _):
            return LoadDiagnosticError.mapping(
                underlying, to: AppUpdateCheckFailure.decodingFailed(underlying.localizedDescription)
            )
        }
    }
}
