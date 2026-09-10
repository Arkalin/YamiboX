import Foundation

/// The upload contract is the site's desktop and touch upload configuration and
/// Discuz X3.5's misc_swfupload responses. Only literal JSON/JSON5 parameters are
/// decoded; site JavaScript is never evaluated.
enum ForumUploadParser {
    static func configurations(in document: Document, pageURL: URL) -> [ForumUploadConfiguration] {
        let scripts = document.select("script:not([src])").array().map { $0.html() }.joined(separator: "\n")
        let desktop = desktopConfigurations(in: scripts, pageURL: pageURL)
        let mobile = mobileConfigurations(in: document, scripts: scripts, pageURL: pageURL)
        return (desktop + mobile).reduce(into: []) { result, configuration in
            if !result.contains(where: { $0.kind == configuration.kind }) { result.append(configuration) }
        }
    }

    private static func desktopConfigurations(in scripts: String, pageURL: URL) -> [ForumUploadConfiguration] {
        guard let pattern = try? NSRegularExpression(pattern: #"new\s+SWFUpload\s*\(\s*\{([\s\S]*?)\}\s*\)"#) else { return [] }
        let range = NSRange(scripts.startIndex..., in: scripts)
        return pattern.matches(in: scripts, range: range).enumerated().compactMap { index, match in
            guard let range = Range(match.range(at: 1), in: scripts) else { return nil }
            let configuration = String(scripts[range])
            guard let rawURL = capture(#"upload_url\s*:\s*["']([^"']+)["']"#, in: configuration),
                  let url = URL(string: rawURL, relativeTo: pageURL)?.absoluteURL,
                  isUploadURL(url),
                  let json = capture(#"post_params\s*:\s*(\{[^}]*\})"#, in: configuration)?.data(using: .utf8),
                  let parameters = (try? JSONSerialization.jsonObject(with: json)) as? [String: String],
                  parameters["uid"]?.isEmpty == false, parameters["hash"]?.isEmpty == false else { return nil }
            let uploadType = capture(#"uploadType\s*:\s*["']([^"']+)["']"#, in: configuration)
            let source = capture(#"uploadSource\s*:\s*["']([^"']+)["']"#, in: configuration)
            let kind: ForumUploadConfiguration.Kind
            if source == "forum", uploadType == "image" { kind = .threadImage }
            else if source == "forum", uploadType == "attach" { kind = .threadAttachment }
            else if uploadType == "blog" { kind = .blogImage }
            else { return nil }
            let kilobytes = capture(#"file_size_limit\s*:\s*["']?(\d+)"#, in: configuration).flatMap(Int.init) ?? 5120
            let fileTypes = capture(#"file_types\s*:\s*["']([^"']+)["']"#, in: configuration) ?? ""
            let extensions = fileTypes.split(separator: ";").map { $0.replacingOccurrences(of: "*.", with: "").lowercased() }.filter { !$0.isEmpty && $0 != "*" }
            return ForumUploadConfiguration(
                id: "upload-\(index)", url: ForumWebPagePolicy.secureURL(url), kind: kind,
                values: parameters.keys.sorted().map { .init(name: $0, value: parameters[$0]!) },
                maximumBytes: min(max(1, kilobytes), 50 * 1024) * 1024, extensions: extensions
            )
        }
    }

    static func isMobileComposerUploadControl(_ control: Element) -> Bool {
        guard control.attr("type").lowercased() == "file", control.attr("name") == "Filedata",
              control.parents().first(where: { $0.tagName() == "form" })?.id() == "postform" else { return false }
        return ["filedata", "attfiledata"].contains(control.id())
    }

    private static func mobileConfigurations(in document: Document, scripts: String, pageURL: URL) -> [ForumUploadConfiguration] {
        guard let pattern = try? NSRegularExpression(pattern: #"\$\s*\.\s*(buildfileupload|ajaxfileupload)\s*\(\s*\{([\s\S]*?)\}\s*\)"#) else { return [] }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        return pattern.matches(in: scripts, range: NSRange(scripts.startIndex..., in: scripts)).compactMap { match in
            guard let methodRange = Range(match.range(at: 1), in: scripts),
                  let bodyRange = Range(match.range(at: 2), in: scripts) else { return nil }
            let isBuilder = scripts[methodRange] == "buildfileupload"
            let body = String(scripts[bodyRange])
            guard let rawURL = literalString(isBuilder ? "uploadurl" : "url", in: body),
                  let url = URL(string: rawURL, relativeTo: pageURL)?.absoluteURL, isUploadURL(url) else { return nil }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []
            guard query.first(where: { $0.name == "operation" })?.value == "upload",
                  query.first(where: { $0.name == "simple" })?.value == "2" else { return nil }
            let uploadType = query.first(where: { $0.name == "type" })?.value
            guard uploadType == nil || uploadType == "image" else { return nil }
            let isImage = uploadType == "image"
            let fieldID = isImage ? "filedata" : "attfiledata"
            guard isBuilder ? literalString("uploadinputname", in: body) == "Filedata" : literalString("fileElementId", in: body) == fieldID,
                  let control = document.select("input[type=file]").first(where: { $0.id() == fieldID && isMobileComposerUploadControl($0) }),
                  !control.hasAttribute("disabled"),
                  !control.parents().contains(where: { $0.tagName() == "fieldset" && $0.hasAttribute("disabled") }) else { return nil }
            let parameterKey = isBuilder ? "uploadformdata" : "data"
            guard let data = capture("\\b\(parameterKey)\\s*:\\s*(\\{[^}]*\\})", in: body)?.data(using: .utf8),
                  let parameters = try? decoder.decode([String: String].self, from: data),
                  (parameters["uid"].flatMap(Int.init) ?? 0) > 0, parameters["hash"]?.isEmpty == false,
                  parameters["type"] == nil || parameters["type"] == uploadType,
                  parameters.keys.allSatisfy({ ["uid", "hash", "type"].contains($0) }) else { return nil }
            let kilobytes = capture(#"\bmaxfilesize\s*:\s*["']?(\d+)"#, in: body).flatMap(Int.init) ?? 5120
            let extensions = control.attr("accept").split(separator: ",").compactMap { token -> String? in
                let value = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return value.hasPrefix(".") ? String(value.dropFirst()) : nil
            }
            return ForumUploadConfiguration(
                id: "mobile-\(fieldID)", url: ForumWebPagePolicy.secureURL(url), kind: isImage ? .threadImage : .threadAttachment,
                values: parameters.keys.sorted().map { .init(name: $0, value: parameters[$0]!) },
                maximumBytes: min(max(1, kilobytes), 50 * 1024) * 1024, extensions: extensions
            )
        }
    }

    private static func literalString(_ key: String, in source: String) -> String? {
        guard let literal = capture("\\b\(key)\\s*:\\s*(\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*')", in: source)?.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        return try? decoder.decode(String.self, from: literal)
    }

    static func isUploadURL(_ url: URL) -> Bool {
        guard ForumWebPagePolicy.requiresForumHandling(url), url.path == "/misc.php" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []
        guard ["mod", "operation", "simple", "type"].allSatisfy({ name in items.filter { $0.name == name }.count <= 1 }) else { return false }
        return items.first { $0.name == "mod" }?.value == "swfupload"
            && ["upload", "album"].contains(items.first { $0.name == "operation" }?.value ?? "")
    }

    static func attachment(from response: String, configuration: ForumUploadConfiguration, name: String) throws -> ForumUploadedAttachment {
        let source = response.trimmingCharacters(in: .whitespacesAndNewlines)
        switch configuration.kind {
        case .threadImage, .threadAttachment:
            let simple = URLComponents(url: configuration.url, resolvingAgainstBaseURL: true)?.queryItems?.first { $0.name == "simple" }?.value
            let rawID: String
            if simple == "2" {
                let fields = source.components(separatedBy: "|")
                guard fields.count >= 8, fields[0] == "DISCUZUPLOAD", fields[2] == "0",
                      fields[1] == (configuration.kind == .threadImage ? "1" : "0") else { throw ForumPageError.uploadFailed }
                rawID = fields[3]
            } else { rawID = source }
            guard let aid = Int(rawID), aid > 0 else { throw ForumPageError.uploadFailed }
            let tag = configuration.kind == .threadImage ? "attachimg" : "attach"
            return ForumUploadedAttachment(
                id: String(aid), name: name, markup: "[\(tag)]\(aid)[/\(tag)]",
                values: [.init(name: "attachnew[\(aid)][description]", value: "")]
            )
        case .blogImage:
            struct AlbumResponse: Decodable { let picid: String; let bigimg: String }
            guard let result = try? JSONDecoder().decode(AlbumResponse.self, from: Data(source.utf8)),
                  let id = Int(result.picid), id > 0,
                  let url = URL(string: result.bigimg, relativeTo: YamiboDomain.baseURL)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw ForumPageError.uploadFailed }
            let escapedURL = url.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
            return ForumUploadedAttachment(
                id: result.picid, name: name, markup: "<img src=\"\(escapedURL)\" alt=\"\">",
                values: [.init(name: "picids[\(result.picid)]", value: result.picid)]
            )
        }
    }

    private static func capture(_ pattern: String, in source: String) -> String? {
        HTMLTextExtractor.firstMatch(pattern: pattern, in: source)?.dropFirst().first
    }
}
