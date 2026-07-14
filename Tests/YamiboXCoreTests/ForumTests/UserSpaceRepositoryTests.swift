import Foundation
import Testing
@testable import YamiboXCore

private final class UserSpaceRepositoryTestURLProtocol: URLProtocol {
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
            client?.urlProtocol(self, didFailWithError: UserSpaceRepositoryTestError.missingHandler)
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

private enum UserSpaceRepositoryTestError: Error {
    case missingHandler
}

private final class PrivateMessageRepositoryTestURLProtocol: URLProtocol {
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
            client?.urlProtocol(self, didFailWithError: UserSpaceRepositoryTestError.missingHandler)
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

@Test func userSpaceRepositoryLoadsAndSubmitsAddFriendFormNatively() async throws {
    defer { UserSpaceRepositoryTestURLProtocol.handler = nil }

    let repository = UserSpaceRepository(
        client: YamiboClient(
            session: makeUserSpaceRepositoryTestSession(),
            cookie: "auth=token",
            userAgent: "Test-UA"
        )
    )
    var postedBody = ""
    var observedMethods: [String] = []

    UserSpaceRepositoryTestURLProtocol.handler = { request in
        observedMethods.append(request.httpMethod ?? "")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=token")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Test-UA")

        switch (request.url?.path, request.httpMethod) {
        case ("/home.php", "GET"):
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.first(where: { $0.name == "mod" })?.value == "spacecp")
            #expect(items.first(where: { $0.name == "ac" })?.value == "friend")
            #expect(items.first(where: { $0.name == "op" })?.value == "add")
            #expect(items.first(where: { $0.name == "uid" })?.value == "705216")
            return userSpaceRepositoryHTTPResponse(url: request.url!, body: addFriendFormHTML())
        case ("/home.php", "POST"):
            postedBody = String(data: request.userSpaceRepositoryHTTPBodyData(), encoding: .utf8) ?? ""
            return userSpaceRepositoryHTTPResponse(
                url: request.url!,
                body: #"<html><body><div class="jump_c">好友请求已送出</div></body></html>"#
            )
        default:
            Issue.record("Unexpected request \(request.httpMethod ?? "nil") \(request.url?.absoluteString ?? "nil")")
            return userSpaceRepositoryHTTPResponse(url: request.url!, body: "", statusCode: 500)
        }
    }

    let form = try await repository.fetchAddFriendForm(uid: "705216", nameHint: "张瑞泽")
    let result = try await repository.addFriend(uid: "705216", formHash: form.formHash, note: "你好", groupID: 2)

    #expect(form.formHash == "form123")
    #expect(form.options.map(\.id) == [1, 2])
    #expect(result == "好友请求已送出")
    #expect(observedMethods == ["GET", "POST"])
    #expect(postedBody.contains("formhash=form123"))
    #expect(postedBody.contains("addsubmit=true"))
    #expect(postedBody.contains("gid=2"))
    #expect(postedBody.contains("note=%E4%BD%A0%E5%A5%BD"))
}

@Test func userSpaceRepositoryLoadsAndSendsPrivateMessageNatively() async throws {
    defer { PrivateMessageRepositoryTestURLProtocol.handler = nil }

    let repository = UserSpaceRepository(
        client: YamiboClient(
            session: makePrivateMessageRepositoryTestSession(),
            cookie: "auth=token",
            userAgent: "Test-UA"
        )
    )
    var postedBody = ""
    var observedMethods: [String] = []

    PrivateMessageRepositoryTestURLProtocol.handler = { request in
        observedMethods.append(request.httpMethod ?? "")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=token")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Test-UA")

        switch (request.url?.path, request.httpMethod) {
        case ("/home.php", "GET"):
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.first(where: { $0.name == "mod" })?.value == "spacecp")
            #expect(items.first(where: { $0.name == "ac" })?.value == "pm")
            #expect(items.first(where: { $0.name == "op" })?.value == "showmsg")
            #expect(items.first(where: { $0.name == "touid" })?.value == "800001")
            return userSpaceRepositoryHTTPResponse(url: request.url!, body: privateMessagePageHTML())
        case ("/home.php", "POST"):
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.first(where: { $0.name == "mod" })?.value == "spacecp")
            #expect(items.first(where: { $0.name == "ac" })?.value == "pm")
            #expect(items.first(where: { $0.name == "op" })?.value == "send")
            #expect(items.first(where: { $0.name == "pmid" })?.value == "900")
            #expect(items.first(where: { $0.name == "touid" })?.value == "800001")
            postedBody = String(data: request.userSpaceRepositoryHTTPBodyData(), encoding: .utf8) ?? ""
            return userSpaceRepositoryHTTPResponse(
                url: request.url!,
                body: #"<html><body><div class="jump_c">短消息发送成功</div></body></html>"#
            )
        default:
            Issue.record("Unexpected request \(request.httpMethod ?? "nil") \(request.url?.absoluteString ?? "nil")")
            return userSpaceRepositoryHTTPResponse(url: request.url!, body: "", statusCode: 500)
        }
    }

    let page = try await repository.fetchPrivateMessagePage(uid: "800001", titleHint: "好友A")
    let result = try await repository.sendPrivateMessage(
        privateMessageID: page.privateMessageID,
        uid: page.toUID,
        formHash: page.formHash ?? "",
        message: "你好"
    )

    #expect(page.privateMessageID == "900")
    #expect(page.formHash == "hash123")
    #expect(page.messages.map(\.contentText) == ["你好"])
    #expect(result == "短消息发送成功")
    #expect(observedMethods == ["GET", "POST"])
    #expect(postedBody.contains("formhash=hash123"))
    #expect(postedBody.contains("pmsubmit=true"))
    #expect(postedBody.contains("pmid=900"))
    #expect(postedBody.contains("touid=800001"))
    #expect(postedBody.contains("message=%E4%BD%A0%E5%A5%BD"))
}

private func makeUserSpaceRepositoryTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UserSpaceRepositoryTestURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makePrivateMessageRepositoryTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PrivateMessageRepositoryTestURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func userSpaceRepositoryHTTPResponse(
    url: URL,
    body: String,
    statusCode: Int = 200
) -> (Data, HTTPURLResponse) {
    (
        Data(body.utf8),
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    )
}

private func addFriendFormHTML() -> String {
    #"""
    <html>
      <body>
        <form>
          <input type="hidden" name="formhash" value="form123" />
          <select name="gid">
            <option value="1">好友</option>
            <option value="2">同好</option>
          </select>
        </form>
      </body>
    </html>
    """#
}

private func privateMessagePageHTML() -> String {
    #"""
    <html>
      <body>
        <form action="home.php?mod=spacecp&amp;ac=pm&amp;op=send&amp;pmid=900&amp;touid=800001&amp;mobile=2">
          <input type="hidden" name="formhash" value="hash123" />
        </form>
        <ul class="pmlist">
          <li id="pm_1">
            <a href="home.php?mod=space&amp;uid=800001&amp;mobile=2">好友A</a>
            <div class="content">你好</div>
          </li>
        </ul>
      </body>
    </html>
    """#
}

private extension URLRequest {
    func userSpaceRepositoryHTTPBodyData() -> Data {
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
