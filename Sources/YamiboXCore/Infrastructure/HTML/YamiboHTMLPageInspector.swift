import Foundation

enum YamiboHTMLPageInspector {
    /// Shared pre-flight for every Yamibo page parser: throws when the page is a
    /// login prompt (`notAuthenticated`) or a flood-control/error page (`floodControl`).
    static func ensureReadable(_ html: String) throws {
        if isNotAuthenticated(html) {
            throw YamiboError.notAuthenticated
        }
        if isFloodControlOrError(html) {
            throw YamiboError.floodControl
        }
    }

    static func isNotAuthenticated(_ html: String) -> Bool {
        let markers = [
            "请先登录",
            "请登录后",
            "您需要先登录",
            "需要登录后才能",
            "登录后才能继续",
            "登录后才能查看"
        ]
        return markers.contains { html.localizedCaseInsensitiveContains($0) }
    }

    static func isFloodControlOrError(_ html: String) -> Bool {
        let markers = [
            "防灌水",
            "灌水预防机制",
            "抱歉，指定的主题不存在或已被删除",
            "您需要先登录才能继续本操作",
            "Sorry, no permission"
        ]
        return markers.contains { html.localizedCaseInsensitiveContains($0) }
    }

    static func pageTitle(from html: String) -> String? {
        if let document = try? KannaSoup.parse(html),
           let title = try? document.title().trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }

        guard let raw = HTMLTextExtractor.firstMatch(
            pattern: #"<title[^>]*>(.*?)</title>"#,
            in: html
        )?.dropFirst().first else {
            return nil
        }

        let title = HTMLTextExtractor.stripTags(raw)
        return title.isEmpty ? nil : title
    }
}

enum YamiboThreadHTMLFacts {
    static func onlyAuthorID(from html: String, threadID: String) -> String? {
        guard let document = try? KannaSoup.parse(html) else { return nil }
        return try? onlyAuthorID(in: document, threadID: threadID)
    }

    static func maxView(from html: String, threadID: String, currentView: Int) -> Int {
        guard let document = try? KannaSoup.parse(html) else {
            return max(1, currentView)
        }
        return maxView(in: document, threadID: threadID, currentView: currentView)
    }

    static func maxView(in document: Document, threadID: String, currentView: Int) -> Int {
        let fallback = max(1, currentView)
        var pages = Set([fallback])

        if let options = try? document.select("select option[value]") {
            for option in options {
                let value = ((try? option.attr("value")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let page = Int(value), page > 0 {
                    pages.insert(page)
                }
            }
        }

        if let links = try? document.select("a[href]") {
            for link in links {
                let href = ((try? link.attr("href")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let components = urlComponents(from: href),
                      isSameThreadLink(components: components, href: href, threadID: threadID),
                      let page = pageNumber(from: components, href: href, threadID: threadID) else {
                    continue
                }
                pages.insert(page)
            }
        }

        return pages.max() ?? fallback
    }

    private static func onlyAuthorID(in document: Document, threadID: String) throws -> String? {
        for link in try document.select("a[href]") {
            let href = try link.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let components = urlComponents(from: href),
                  isSameThreadLink(components: components, href: href, threadID: threadID),
                  let authorID = components.queryItems?.first(where: { $0.name == "authorid" })?.value,
                  !authorID.isEmpty else {
                continue
            }
            return authorID
        }
        return nil
    }

    private static func urlComponents(from href: String) -> URLComponents? {
        guard let url = HTMLTextExtractor.absoluteURL(from: href) else {
            return URLComponents(string: href)
        }
        return URLComponents(url: url, resolvingAgainstBaseURL: true)
    }

    private static func isSameThreadLink(components: URLComponents, href: String, threadID: String) -> Bool {
        if let tid = components.queryItems?.first(where: { $0.name == "tid" })?.value {
            return tid == threadID
        }
        return href.contains("thread-\(threadID)-")
    }

    private static func pageNumber(from components: URLComponents, href: String, threadID: String) -> Int? {
        if let page = components.queryItems?.first(where: { $0.name == "page" })?.value.flatMap(Int.init) {
            return page
        }

        return HTMLTextExtractor.firstMatch(
            pattern: #"thread-\#(threadID)-(\d+)-\d+\.html"#,
            in: href
        )?
        .dropFirst()
        .first
        .flatMap(Int.init)
    }
}
