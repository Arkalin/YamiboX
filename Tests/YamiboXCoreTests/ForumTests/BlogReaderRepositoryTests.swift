import Foundation
import Testing
@testable import YamiboXCore

private final class BlogReaderRepositoryTestURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Data, HTTPURLResponse)

    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: BlogReaderRepositoryTestError.missingHandler)
            return
        }

        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum BlogReaderRepositoryTestError: Error {
    case missingHandler
}

@Test func blogReaderRepositoryPostsBlogCommentNatively() async throws {
    defer { BlogReaderRepositoryTestURLProtocol.handler = nil }

    let repository = BlogReaderRepository(
        client: YamiboClient(
            session: makeBlogReaderRepositoryTestSession(),
            cookie: "auth=token",
            userAgent: "Test-UA"
        )
    )
    var postedBody = ""

    BlogReaderRepositoryTestURLProtocol.handler = { request in
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=token")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Test-UA")
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        #expect(request.url?.path == "/home.php")
        #expect(items.value(named: "mod") == "spacecp")
        #expect(items.value(named: "ac") == "comment")
        #expect(items.value(named: "op") == "add")
        #expect(items.value(named: "id") == "88")
        #expect(items.value(named: "idtype") == "blogid")
        #expect(items.value(named: "uid") == "705216")
        postedBody = String(data: request.blogReaderRepositoryHTTPBodyData(), encoding: .utf8) ?? ""
        return blogReaderRepositoryHTTPResponse(
            url: request.url!,
            body: #"<html><body><div class="jump_c">评论发表成功</div></body></html>"#
        )
    }

    let result = try await repository.postBlogComment(
        blogID: "88",
        uid: "705216",
        message: "好文",
        formHash: "form123"
    )

    #expect(result == "评论发表成功")
    #expect(postedBody.contains("formhash=form123"))
    #expect(postedBody.contains("commentsubmit=true"))
    #expect(postedBody.contains("id=88"))
    #expect(postedBody.contains("idtype=blogid"))
    #expect(postedBody.contains("uid=705216"))
    #expect(postedBody.contains("message=%E5%A5%BD%E6%96%87"))
}

private func makeBlogReaderRepositoryTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BlogReaderRepositoryTestURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func blogReaderRepositoryHTTPResponse(
    url: URL,
    body: String,
    statusCode: Int = 200
) -> (Data, HTTPURLResponse) {
    (
        Data(body.utf8),
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    )
}

private extension URLRequest {
    func blogReaderRepositoryHTTPBodyData() -> Data {
        if let httpBody {
            return httpBody
        }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private extension Array where Element == URLQueryItem {
    func value(named name: String) -> String? {
        first(where: { $0.name == name })?.value
    }
}
