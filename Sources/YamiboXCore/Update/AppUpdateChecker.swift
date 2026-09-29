import Foundation

public enum AppUpdateCheckFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse(statusCode: Int?)
    case emptyBody
    case decodingFailed(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidResponse(statusCode):
            if let statusCode {
                return L10n.string("app_update.error.invalid_response_with_status", statusCode)
            }
            return L10n.string("app_update.error.invalid_response")
        case .emptyBody:
            return L10n.string("app_update.error.empty_body")
        case let .decodingFailed(message):
            return L10n.string("app_update.error.decoding_failed", message)
        case let .network(message):
            return L10n.string("app_update.error.network", message)
        }
    }
}

public enum AppUpdateCheckResult: Equatable, Sendable {
    case upToDate
    case updateAvailable(version: AppSourceVersion)
    case sourceDoesNotContainCurrentApp
    case failure(AppUpdateCheckFailure)
}

public struct AppUpdateCheckOutcome: Sendable {
    public let result: AppUpdateCheckResult
    public let details: LoadFailureDetails?
    public let isCancelled: Bool

    public init(result: AppUpdateCheckResult, details: LoadFailureDetails? = nil, isCancelled: Bool = false) {
        self.result = result
        self.details = details
        self.isCancelled = isCancelled
    }
}

public struct AppUpdateChecker: Sendable {
    public static let defaultSourceURL = URL(string: "https://raw.githubusercontent.com/Arkalin/YamiboX/main/app-repo.json")!

    let session: URLSession?
    private let sourceLoader: AppSourceLoader

    public init(session: URLSession = YamiboNetworkConfiguration.makeSession()) {
        self.session = session
        sourceLoader = AppSourceLoader(session: session)
    }

    init(fetchData: @escaping @Sendable (URL) async throws -> (Data, URLResponse)) {
        session = nil
        sourceLoader = AppSourceLoader(fetchData: fetchData)
    }

    public func checkForUpdate(
        sourceURL: URL = Self.defaultSourceURL,
        currentBundleIdentifier: String,
        currentVersion: String
    ) async -> AppUpdateCheckResult {
        await checkForUpdateWithDetails(
            sourceURL: sourceURL, currentBundleIdentifier: currentBundleIdentifier, currentVersion: currentVersion
        ).result
    }

    public func checkForUpdateWithDetails(
        sourceURL: URL = Self.defaultSourceURL,
        currentBundleIdentifier: String,
        currentVersion: String
    ) async -> AppUpdateCheckOutcome {
        do {
            let (data, response) = try await sourceLoader.fetch(sourceURL: sourceURL)
            return Self.checkForUpdateWithDetails(
                data: data,
                response: response,
                currentBundleIdentifier: currentBundleIdentifier,
                currentVersion: currentVersion
            )
        } catch {
            let cancelled = Task.isCancelled || LoadDiagnosticError.isCancellation(error)
            return .init(result: .failure(.network(error.localizedDescription)),
                         details: cancelled ? nil : LoadFailureDetails(error: error, requestContext: sourceURL.absoluteString),
                         isCancelled: cancelled)
        }
    }

    public static func checkForUpdate(
        data: Data,
        response: URLResponse,
        currentBundleIdentifier: String,
        currentVersion: String
    ) -> AppUpdateCheckResult {
        checkForUpdateWithDetails(data: data, response: response,
                                  currentBundleIdentifier: currentBundleIdentifier, currentVersion: currentVersion).result
    }

    private static func checkForUpdateWithDetails(
        data: Data,
        response: URLResponse,
        currentBundleIdentifier: String,
        currentVersion: String
    ) -> AppUpdateCheckOutcome {
        do {
            let source = try AppSourceLoader.decode(data: data, response: response)
            return .init(result: checkForUpdate(
                source: source,
                currentBundleIdentifier: currentBundleIdentifier,
                currentVersion: currentVersion
            ))
        } catch let failure as AppSourceLoader.Failure {
            return outcome(for: failure)
        } catch {
            return .init(result: .failure(.decodingFailed(error.localizedDescription)),
                         details: LoadFailureDetails(error: error, requestContext: response.url?.absoluteString))
        }
    }

    private static func outcome(for failure: AppSourceLoader.Failure) -> AppUpdateCheckOutcome {
        switch failure {
        case let .invalidResponse(statusCode, responseURL):
            let result = AppUpdateCheckFailure.invalidResponse(statusCode: statusCode)
            guard let statusCode else {
                return .init(result: .failure(result))
            }
            return .init(
                result: .failure(result),
                details: LoadFailureDetails(error: LoadDiagnosticError.attaching(
                    to: result, requestContext: responseURL, httpStatus: statusCode
                ))
            )
        case .emptyBody:
            return .init(result: .failure(.emptyBody))
        case let .decodingFailed(underlying, responseURL):
            return .init(
                result: .failure(.decodingFailed(underlying.localizedDescription)),
                details: LoadFailureDetails(error: underlying, requestContext: responseURL)
            )
        }
    }

    public static func checkForUpdate(
        source: AppSource,
        currentBundleIdentifier: String,
        currentVersion: String
    ) -> AppUpdateCheckResult {
        guard let app = source.apps.first(where: { $0.bundleIdentifier == currentBundleIdentifier }) else {
            return .sourceDoesNotContainCurrentApp
        }
        guard let latest = app.versions.first else {
            return .upToDate
        }

        if AppVersionComparator.compare(latest.version, currentVersion) == .orderedDescending {
            return .updateAvailable(version: latest)
        }
        return .upToDate
    }
}

enum AppVersionComparator {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let lhsComponents = numericComponents(lhs),
           let rhsComponents = numericComponents(rhs) {
            let count = max(lhsComponents.count, rhsComponents.count)
            for index in 0 ..< count {
                let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
                let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
                if lhsValue > rhsValue { return .orderedDescending }
                if lhsValue < rhsValue { return .orderedAscending }
            }
            return .orderedSame
        }

        return lhs.compare(rhs, options: [.caseInsensitive, .numeric])
    }

    private static func numericComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var components: [Int] = []
        components.reserveCapacity(parts.count)
        for part in parts {
            guard let value = Int(part) else { return nil }
            components.append(value)
        }
        return components
    }
}
