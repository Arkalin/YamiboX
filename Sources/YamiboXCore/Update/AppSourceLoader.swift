import Foundation

/// Loads and decodes the app source without deciding how a surface presents failures.
struct AppSourceLoader: Sendable {
    enum Failure: Error {
        case invalidResponse(statusCode: Int?, responseURL: String?)
        case emptyBody(responseURL: String?)
        case decodingFailed(underlying: any Error, responseURL: String?)
    }

    private let fetchData: @Sendable (URL) async throws -> (Data, URLResponse)

    init(session: URLSession) {
        fetchData = { url in
            var request = YamiboNetworkConfiguration.makeRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return try await session.data(for: request)
        }
    }

    init(fetchData: @escaping @Sendable (URL) async throws -> (Data, URLResponse)) {
        self.fetchData = fetchData
    }

    func fetch(sourceURL: URL) async throws -> (Data, URLResponse) {
        try await fetchData(sourceURL)
    }

    static func decode(data: Data, response: URLResponse) throws -> AppSource {
        let responseURL = response.url?.absoluteString
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Failure.invalidResponse(statusCode: nil, responseURL: responseURL)
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            throw Failure.invalidResponse(statusCode: httpResponse.statusCode, responseURL: responseURL)
        }
        guard !data.isEmpty else {
            throw Failure.emptyBody(responseURL: responseURL)
        }

        do {
            return try JSONDecoder().decode(AppSource.self, from: data)
        } catch {
            throw Failure.decodingFailed(underlying: error, responseURL: responseURL)
        }
    }
}
