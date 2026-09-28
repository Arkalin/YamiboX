import Foundation

enum ForumComposerContextParser {
    static func parse(in document: Document, pageURL: URL, isFirstPost: Bool) -> ForumComposerContext? {
        guard let form = document.selectFirst("#postform, #fastpostform") else { return nil }
        let scripts = document.select("script:not([src])").array().map { $0.html() }.joined(separator: "\n")
        let actionURL = URL(string: form.attr("action"), relativeTo: pageURL)?.absoluteURL ?? pageURL
        let query = (URLComponents(url: pageURL, resolvingAgainstBaseURL: true)?.queryItems ?? []) + (URLComponents(url: actionURL, resolvingAgainstBaseURL: true)?.queryItems ?? [])
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value ?? form.select("input[name]").first { $0.attr("name") == name }?.attr("value").nilIfBlank
        }
        let kind: ForumComposerTarget.Kind
        switch value("action") {
        case "newthread": kind = .newThread
        case "reply": kind = .reply
        case "edit": kind = isFirstPost ? .editFirstPost : .editReply
        default: kind = .unknown
        }
        var context = ForumComposerContext(
            target: .init(kind: kind, forumID: value("fid"), threadID: value("tid"), postID: value("pid"), special: value("special"), replyPostID: value("repquote")),
            bbcode: literalFlag("allowbbcode", in: scripts), images: literalFlag("allowimgcode", in: scripts),
            media: literalFlag("allowmediacode", in: scripts), emoticons: literalFlag("allowsmilies", in: scripts)
        )
        let buttons: [String: ForumComposerTag] = ["aud": .audio, "vid": .media, "fls": .flash, "hide": .hide, "free": .free, "beginning": .begin, "collapse": .collapse]
        for element in document.select("[id]") {
            let id = element.id()
            if let suffix = id.split(separator: "_").last, let tag = buttons[String(suffix)], id.hasPrefix("e_") { context.tags[tag] = .allowed }
            if id.hasPrefix("e_cst1_") || id.hasPrefix("e_cst2_"), let tag = ForumComposerTag.named(String(id.split(separator: "_").last ?? "")) {
                context.tags[tag] = .allowed
            }
        }
        for (name, tag) in [("allowhidecode", ForumComposerTag.hide), ("allowbegincode", .begin)] {
            let value = literalFlag(name, in: scripts)
            if value != .unknown { context.tags[tag] = value }
        }
        var attachments: [String: ForumComposerAttachmentReference] = [:]
        for image in document.select("img") {
            let rawID = image.attr("aid").nilIfBlank ?? image.attr("data-aid").nilIfBlank
                ?? (image.id().hasPrefix("aimg_") ? String(image.id().dropFirst(5)) : "")
            guard let id = Int(rawID), id > 0 else { continue }
            let rawURL = image.attr("file").nilIfBlank ?? image.attr("zoomfile").nilIfBlank ?? image.attr("src")
            let preview = ForumComposerSyntax.safeURL(rawURL, relativeTo: pageURL)
            attachments[String(id)] = .init(id: String(id), name: image.attr("alt").nilIfBlank ?? String(id), previewURL: preview, isImage: true)
        }
        for input in form.select("input[name]") {
            guard let rawID = HTMLTextExtractor.firstMatch(pattern: #"^attach(?:new)?\[(\d+)\]"#, in: input.attr("name"))?.dropFirst().first,
                  let id = Int(rawID), id > 0, attachments[String(id)] == nil else { continue }
            let name = document.selectFirst("#attachname_\(id)")?.text().nilIfBlank ?? String(id)
            attachments[String(id)] = .init(id: String(id), name: name)
        }
        context.attachments = attachments.values.sorted { $0.id < $1.id }
        context.backgrounds = backgrounds(in: scripts, baseURL: pageURL)
        for script in document.select("script[src]") {
            guard let url = ForumComposerSyntax.safeURL(script.attr("src"), relativeTo: pageURL),
                  ForumWebPagePolicy.requiresForumHandling(url), url.path == "/data/cache/common_postimg.js" else { continue }
            context.backgroundCatalogURL = url
            break
        }
        return context
    }

    static func backgrounds(in source: String, baseURL: URL) -> [ForumComposerBackground] {
        guard source.utf8.count <= 256 * 1024,
              let raw = HTMLTextExtractor.firstMatch(pattern: #"postimg_type\s*\[\s*["']postbg["']\s*\]\s*=\s*(\[(?:\s*(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')\s*,?)*\])"#, in: source)?.dropFirst().first else { return [] }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        guard let names = try? decoder.decode([String].self, from: Data(raw.utf8)) else { return [] }
        var seen = Set<String>()
        return names.compactMap { name in
            guard name.utf8.count < 30, !name.contains("/"), !name.contains("\\"),
                  ["jpg", "gif", "png"].contains((name as NSString).pathExtension.lowercased()), seen.insert(name).inserted else { return nil }
            guard let root = URL(string: "/static/image/postbg/", relativeTo: baseURL)?.absoluteURL else { return nil }
            let url = root.appendingPathComponent(name)
            guard ForumWebPagePolicy.requiresForumHandling(url) else { return nil }
            return .init(name: name, imageURL: ForumWebPagePolicy.secureURL(url))
        }
    }

    private static func literalFlag(_ name: String, in source: String) -> ForumComposerContext.Capability {
        let key = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?:^|[;\\r\\n])\\s*(?:var\\s+)?\(key)\\s*=\\s*(?:parseInt\\(\\s*['\"]([01])['\"]\\s*\\)|([01]))\\s*;"
        guard let captures = HTMLTextExtractor.firstMatch(pattern: pattern, in: source),
              let value = captures.dropFirst().first(where: { $0 == "0" || $0 == "1" }) else { return .unknown }
        return value == "1" ? .allowed : .denied
    }
}
