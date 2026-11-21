import Foundation

enum YamiboHTMLPageInspector {
    private static let invisibleTags: Set<String> = ["script", "style", "template", "noscript", "textarea"]
    private static let noticeContainers = "#messagetext, .messagetext, .jump_c, .alert_error, .alert_info, .showmessage"
    private static let loginMarkers = [
        "请先登录", "請先登錄", "请登录后", "您需要先登录", "需要登录后才能",
        "登录后才能继续", "登录后才能查看", "请输入用户名/Email/UID",
        "尚未登录，无法进行此操作", "尚未登入，無法進行此操作"
    ]
    private static let floodMarkers = [
        "防灌水", "灌水预防机制", "抱歉，指定的主题不存在或已被删除", "Sorry, no permission"
    ]

    static func ensureReadable(_ html: String) throws {
        guard let document = try? KannaSoup.parse(html) else { return }
        if needsAuthentication(document) {
            throw YamiboError.notAuthenticated
        }
        if containsNotice(in: document, markers: floodMarkers) {
            throw YamiboError.floodControl
        }
    }

    static func isNotAuthenticated(_ html: String) -> Bool {
        guard let document = try? KannaSoup.parse(html) else { return false }
        return needsAuthentication(document)
    }

    static func isFloodControlOrError(_ html: String) -> Bool {
        guard let document = try? KannaSoup.parse(html) else { return false }
        return containsNotice(in: document, markers: floodMarkers)
    }

    static func isVisibleNotice(_ element: Element) -> Bool {
        isVisible(element) && element.parents().allSatisfy(isVisible)
    }

    static func visibleNoticeText(_ element: Element) -> String {
        element.visibleText(including: isVisible)
    }

    static func visibleBody(in document: Document) -> Element? {
        guard let body = document.body(), isVisibleNotice(body) else { return nil }
        return body
    }

    private static func isVisible(_ element: Element) -> Bool {
        let style = element.attr("style").lowercased().filter { !$0.isWhitespace }
        return !invisibleTags.contains(element.tagName().lowercased())
            && !element.hasAttribute("hidden") && element.attr("aria-hidden").lowercased() != "true"
            && !style.contains("display:none") && !style.contains("visibility:hidden")
    }

    private static func needsAuthentication(_ document: Document) -> Bool {
        if visibleBody(in: document)?.hasClass("pg_logging") == true { return true }
        if document.selectAll("#loginform, form[action*='action=login']")
            .contains(where: { isVisibleNotice($0) && $0.selectFirst("input[type='password']") != nil }) {
            return !document.selectAll(".threadlist_box, #postlist, .viewthread, #threadlist")
                .contains(where: isVisibleNotice) || containsNotice(in: document, markers: loginMarkers)
        }
        return containsNotice(in: document, markers: loginMarkers)
    }

    private static func containsNotice(in document: Document, markers: [String]) -> Bool {
        let noticeTexts = document.selectAll(noticeContainers)
            .filter(isVisibleNotice)
            .map(visibleNoticeText)
        if noticeTexts.contains(where: { notice in
            markers.contains(where: notice.localizedCaseInsensitiveContains)
        }) {
            return true
        }

        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "。！!"))
        let legacyText = visibleBody(in: document)?.ownText().trimmingCharacters(in: edges) ?? ""
        return markers.contains { legacyText.localizedCaseInsensitiveCompare($0) == .orderedSame }
    }

    static func pageTitle(from html: String) -> String? {
        if let document = try? KannaSoup.parse(html) {
            return pageTitle(in: document, rawHTML: html)
        }

        return rawPageTitle(from: html)
    }

    static func pageTitle(in document: Document, rawHTML html: String) -> String? {
        let title = document.title().trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }

        return rawPageTitle(from: html)
    }

    private static func rawPageTitle(from html: String) -> String? {
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
        return onlyAuthorID(in: document, threadID: threadID)
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

        for option in document.select("select option[value]") {
            let value = option.attr("value").trimmingCharacters(in: .whitespacesAndNewlines)
            if let page = Int(value), page > 0 {
                pages.insert(page)
            }
        }

        for link in document.select("a[href]") {
            let href = link.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let components = urlComponents(from: href),
                  isSameThreadLink(components: components, href: href, threadID: threadID),
                  let page = pageNumber(from: components, href: href, threadID: threadID) else {
                continue
            }
            pages.insert(page)
        }

        return pages.max() ?? fallback
    }

    private static func onlyAuthorID(in document: Document, threadID: String) -> String? {
        for link in document.select("a[href]") {
            let href = link.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
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
