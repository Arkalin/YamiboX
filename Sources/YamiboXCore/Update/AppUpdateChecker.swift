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

public struct AppUpdateChecker: Sendable {
    public static let defaultSourceURL = URL(string: "https://raw.githubusercontent.com/Arkalin/YamiboX/main/app-repo.json")!

    let session: URLSession?
    private let fetchData: @Sendable (URL) async throws -> (Data, URLResponse)

    public init(session: URLSession = YamiboNetworkConfiguration.makeSession()) {
        self.session = session
        fetchData = { url in
            var request = YamiboNetworkConfiguration.makeRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return try await session.data(for: request)
        }
    }

    init(fetchData: @escaping @Sendable (URL) async throws -> (Data, URLResponse)) {
        session = nil
        self.fetchData = fetchData
    }

    public func checkForUpdate(
        sourceURL: URL = Self.defaultSourceURL,
        currentBundleIdentifier: String,
        currentVersion: String
    ) async -> AppUpdateCheckResult {
        do {
            let (data, response) = try await fetchData(sourceURL)
            return Self.checkForUpdate(
                data: data,
                response: response,
                currentBundleIdentifier: currentBundleIdentifier,
                currentVersion: currentVersion
            )
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    public static func checkForUpdate(
        data: Data,
        response: URLResponse,
        currentBundleIdentifier: String,
        currentVersion: String
    ) -> AppUpdateCheckResult {
        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(.invalidResponse(statusCode: nil))
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            return .failure(.invalidResponse(statusCode: httpResponse.statusCode))
        }
        guard !data.isEmpty else {
            return .failure(.emptyBody)
        }

        do {
            let source = try JSONDecoder().decode(AppSource.self, from: data)
            return checkForUpdate(
                source: source,
                currentBundleIdentifier: currentBundleIdentifier,
                currentVersion: currentVersion
            )
        } catch {
            return .failure(.decodingFailed(error.localizedDescription))
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
