import Foundation
@testable import YamiboXCore

/// In-memory HTTP server with actual conditional-write semantics. It is also
/// used for capability probes in older, payload-focused URLProtocol fixtures.
final class WebDAVMemoryServer: @unchecked Sendable {
    private struct File {
        var data: Data
        var etag: String
    }
    private let lock = NSLock()
    private var files: [String: File] = [:]
    private var revision = 0
    private var writes = 0
    private var conflictCount = 0
    private var conflictPayload: Data?
    let omitsETags: Bool
    let ignoresConditions: Bool

    init(omitsETags: Bool = false, ignoresConditions: Bool = false) {
        self.omitsETags = omitsETags
        self.ignoresConditions = ignoresConditions
    }

    var payloadWriteCount: Int { lock.withLock { writes } }
    var probeFileCount: Int { lock.withLock { files.keys.filter { $0.hasPrefix(".yamibox-sync-probe-") }.count } }

    func seed(_ name: String, data: Data) {
        lock.withLock { put(name, data: data) }
    }

    func data(_ name: String) -> Data? { lock.withLock { files[name]?.data } }

    func conflictNextWrites(_ count: Int, replacingWith data: Data? = nil) {
        lock.withLock {
            conflictCount = count
            conflictPayload = data
        }
    }

    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let body = request.testWebDAVBody()
        return lock.withLock {
            let name = url.lastPathComponent
            func response(_ status: Int, _ file: File? = nil) -> (Data, HTTPURLResponse) {
                var headers: [String: String] = [:]
                if let file, !omitsETags { headers["ETag"] = file.etag }
                return (file?.data ?? Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
            }
            switch request.httpMethod {
            case "GET":
                guard let file = files[name] else { return response(404) }
                return response(200, file)
            case "MKCOL":
                return response(201)
            case "DELETE":
                files[name] = nil
                return response(204)
            case "PUT":
                if !name.hasPrefix(".yamibox-sync-probe-") {
                    writes += 1
                    if conflictCount > 0 {
                        conflictCount -= 1
                        if let conflictPayload { put(name, data: conflictPayload) }
                        return response(412)
                    }
                }
                if !ignoresConditions {
                    if request.value(forHTTPHeaderField: "If-None-Match") == "*", files[name] != nil { return response(412) }
                    if let expected = request.value(forHTTPHeaderField: "If-Match"), files[name]?.etag != expected { return response(412) }
                }
                put(name, data: body)
                return response(201, files[name])
            default:
                return response(405)
            }
        }
    }

    private func put(_ name: String, data: Data) {
        revision += 1
        files[name] = File(data: data, etag: "\"revision-\(revision)\"")
    }
}

extension URLRequest {
    func testWebDAVBody() -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}
