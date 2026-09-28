import Foundation

struct YamiboHTTPResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse

    func decodeHTML() throws -> String {
        do {
            guard 200 ..< 300 ~= response.statusCode else {
                if response.statusCode == 401 {
                    throw YamiboError.notAuthenticated
                }
                throw YamiboError.invalidResponse(statusCode: response.statusCode)
            }
            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) else {
                throw YamiboError.unreadableBody
            }
            guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw YamiboError.emptyHTML
            }
            return html
        } catch {
            throw LoadDiagnosticError.attaching(to: error, requestContext: response.url?.absoluteString, httpStatus: response.statusCode)
        }
    }
}
