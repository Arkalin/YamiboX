import Foundation

/// Extracts native forms and explicit status messages, never general page content.
enum ForumFormPageParser {
    static func parse(html: String, url: URL) throws -> ForumPageDocument {
        let payload = HTMLTextExtractor.discuzAjaxPayload(from: html) ?? html
        let document = try KannaSoup.parse(payload, baseURL: url.absoluteString)
        let uploads = ForumUploadParser.configurations(in: document, pageURL: url)
        let isFirstPost = composerIsFirstPost(in: document)
        let composerContext = ForumComposerContextParser.parse(in: document, pageURL: url, isFirstPost: isFirstPost)
        resolveComposerTabs(in: document, pageURL: url)
        let composerLinks = document.select("a[data-native-composer-tab]").array().compactMap { link -> ForumComposerLink? in
            guard let url = link.attrURL("href") else { return nil }
            return ForumComposerLink(title: link.normalizedText(), url: url)
        }
        // These are desktop upload dialog forms, not independent user forms.
        // Remove their chrome too; otherwise hidden dialog text leaks below
        // the native composer even when its controls were excluded.
        document.select("#e_menus, #e_image_menu, #e_attach_menu, form[id=imgattachform], form[id^=imgattachform_], form[id=attachform], form[id^=attachform_]").remove()
        // Do not mistake the desktop header's inline login form for a login page.
        if document.select("body.pg_logging, #main_messaqge #loginform, .loginbox").count > 0 {
            throw YamiboError.notAuthenticated
        }
        document.select("script, style, noscript, #hd, #toptb, #nv, #qmenu_menu, #scbar, #scbar_form, #ft, #scrolltop").remove()
        let root = document.selectFirst("#ct") ?? document.selectFirst("#wp") ?? document.body() ?? document
        let title = pageTitle(document: document, root: root)
        let forms = try root.select("form").array().enumerated().compactMap { index, form in
            try parseForm(form, index: index, pageURL: url, pageTitle: title, isFirstPost: isFirstPost)
        }
        if forms.contains(where: { $0.kind != .standard }) { root.select("#pt").remove() }
        let message = root.selectFirst("#messagetext, .jump_c, .alert_error, .alert_info, .showmessage")?.text().nilIfBlank
        if let message, ["请先登录", "請先登錄", "请登录后", "您需要先登录"].contains(where: message.contains) {
            throw YamiboError.notAuthenticated
        }
        let continuationURL = continuationURL(document: document, root: root, baseURL: url)
        return ForumPageDocument(url: url, title: title, forms: forms, message: message, continuationURL: continuationURL, uploads: uploads, composerContext: composerContext, composerLinks: composerLinks)
    }

    private static func pageTitle(document: Document, root: Element) -> String {
        let title = document.title().components(separatedBy: " - ").first?.nilIfBlank
        return title ?? root.selectFirst("h1, h2, .flb em")?.text().nilIfBlank ?? L10n.string("forum.native.title")
    }

    private static func parseForm(_ element: Element, index: Int, pageURL: URL, pageTitle: String, isFirstPost: Bool) throws -> ForumForm? {
        let formID = element.id().nilIfBlank ?? "form-\(index)"
        guard !["scbar_form", "loginform"].contains(formID) else { return nil }
        let action = element.attr("action").nilIfBlank ?? pageURL.absoluteString
        guard let actionURL = resolvedURL(action, baseURL: pageURL), ForumWebPagePolicy.requiresForumHandling(actionURL) else { return nil }
        let method = element.attr("method").nilIfBlank?.uppercased() ?? "GET"
        let items = URLComponents(url: actionURL, resolvingAgainstBaseURL: true)?.queryItems ?? []
        let value: (String) -> String? = { key in items.first { $0.name == key }?.value }
        let postAction = value("action") ?? URLComponents(url: pageURL, resolvingAgainstBaseURL: true)?.queryItems?.first { $0.name == "action" }?.value
        let kind: ForumForm.Kind
        if formID == "postform" || formID == "fastpostform" || (actionURL.path == "/forum.php" && value("mod") == "post") {
            kind = .thread
        } else if formID == "ttHtmlEditor" || (value("ac") == "blog" && !element.select("textarea[name=message]").isEmpty) {
            kind = .blog
        } else {
            kind = .standard
        }

        // Browser editor helpers and upload dialogs are not successful composer
        // controls. Their functionality is supplied by the native editor.
        let controls = element.select("input, textarea, select, button").array().filter { control in
            guard !control.hasAttribute("disabled"),
                  !control.parents().contains(where: { $0.tagName() == "fieldset" && $0.hasAttribute("disabled") }) else { return false }
            guard control.parents().first(where: { $0.tagName() == "form" })?.id() == element.id() else { return false }
            if kind == .thread {
                let name = control.attr("name")
                return name != "checkbox" && !name.hasPrefix("e_") && !ForumUploadParser.isMobileComposerUploadControl(control)
            }
            if kind == .blog {
                return !["savealbumid", "newalbum", "view_albumid", "selectgroup", "file"].contains(control.attr("name"))
            }
            return true
        }
        var hiddenValues: [ForumFormValue] = []
        var fields: [ForumFormField] = []
        var buttons: [ForumFormButton] = []
        var radioNames: Set<String> = []
        for (controlIndex, control) in controls.enumerated() {
            let type = control.attr("type").lowercased()
            let tag = control.tagName().lowercased()
            let name = control.attr("name")
            let id = "\(formID)-\(controlIndex)"
            if type == "submit" || (tag == "button" && type.isEmpty) {
                let title = control.text().nilIfBlank ?? control.attr("value").nilIfBlank ?? L10n.string("common.confirm")
                buttons.append(ForumFormButton(
                    id: id, title: title,
                    values: name.isEmpty ? [] : [ForumFormValue(name: name, value: control.attr("value"))]
                ))
                continue
            }
            if kind == .thread, tag == "button", type == "button", control.text().contains("保存草稿") {
                buttons.append(ForumFormButton(id: id, title: control.text(), values: [.init(name: "save", value: "1")]))
                continue
            }
            guard !name.isEmpty, !["button", "reset", "image"].contains(type) else { continue }
            let preservesReplySubject = kind == .thread && name == "subject" &&
                (postAction == "reply" || (postAction == "edit" && !isFirstPost))
            if type == "hidden" || preservesReplySubject {
                hiddenValues.append(ForumFormValue(name: name, value: control.attr("value")))
                continue
            }
            let label = fieldLabel(control, form: element)
            let fieldKind: ForumFormField.Kind
            var selected: [String]
            var options: [ForumFormOption] = []
            if tag == "select" {
                fieldKind = control.hasAttribute("multiple") ? .multipleChoice : .choice
                let nodes = control.select("option").array().filter { !$0.hasAttribute("disabled") }
                var seen: Set<String> = []
                for option in nodes {
                    let optionValue = option.hasAttribute("value") ? option.attr("value") : option.text()
                    // Discuz uses these sentinel values for JS dialogs, not form
                    // submissions. Never send them as real category identifiers.
                    guard optionValue != "addoption", seen.insert(optionValue).inserted else { continue }
                    options.append(.init(value: optionValue, label: option.text()))
                }
                selected = nodes.filter { $0.hasAttribute("selected") }.map { $0.hasAttribute("value") ? $0.attr("value") : $0.text() }
                selected = selected.filter { value in options.contains { $0.value == value } }
                if fieldKind == .choice {
                    selected = Array(selected.suffix(1))
                    if selected.isEmpty, let first = options.first { selected = [first.value] }
                }
            } else if type == "radio" {
                guard radioNames.insert(name).inserted else { continue }
                fieldKind = .choice
                let radios = controls.filter { $0.attr("type").lowercased() == "radio" && $0.attr("name") == name }
                var seen: Set<String> = []
                options = radios.compactMap { radio in
                    let value = radio.hasAttribute("value") ? radio.attr("value") : "on"
                    guard seen.insert(value).inserted else { return nil }
                    return .init(value: value, label: fieldLabel(radio, form: element))
                }
                selected = radios.filter { $0.hasAttribute("checked") }.map { $0.hasAttribute("value") ? $0.attr("value") : "on" }
                selected = Array(selected.suffix(1))
            } else if type == "checkbox" {
                fieldKind = .toggle
                let value = control.hasAttribute("value") ? control.attr("value") : "on"
                options = [.init(value: value, label: label)]
                selected = control.hasAttribute("checked") ? [value] : []
            } else {
                switch (tag, type) {
                case ("textarea", _): fieldKind = .multiline
                case (_, "password"): fieldKind = .password
                case (_, "email"): fieldKind = .email
                case (_, "number"): fieldKind = .number
                case (_, "file"): fieldKind = .file
                default: fieldKind = .text
                }
                selected = [tag == "textarea" ? control.textareaValue : control.attr("value")]
            }
            fields.append(ForumFormField(
                id: id, name: name, label: label, kind: fieldKind, initialValues: selected, options: options,
                isRequired: control.hasAttribute("required") || ((kind == .thread || kind == .blog) && (name == "message" || (name == "subject" && value("action") != "reply"))),
                isReadOnly: control.hasAttribute("readonly"), maxLength: Int(control.attr("maxlength"))
            ))
        }
        // Forms without a submit action are UI helpers, not stand-alone pages.
        guard !buttons.isEmpty else { return nil }
        var instructions: [ForumThreadContentBlock] = []
        let instructionNodes = element.select(".alert_info, .notice, .description, .c").array()
        for node in instructionNodes where node.select("textarea, select, input:not([type=hidden])").isEmpty {
            let copy = try KannaSoup.parseBodyFragment(node.html())
            copy.select("input, button, script, style").remove()
            resolveReferences(in: copy, baseURL: pageURL)
            instructions += try ForumThreadHTMLBlockParser.parseBlocks(in: copy.body() ?? copy)
        }
        return ForumForm(
            id: formID, title: pageTitle, actionURL: ForumWebPagePolicy.secureURL(actionURL), method: method, kind: kind,
            fields: fields, hiddenValues: hiddenValues, buttons: buttons, instructions: instructions,
            isDestructive: ["delete", "ignore", "remove"].contains(value("op") ?? "") || buttons.contains { $0.title.contains("删除") }
        )
    }

    private static func composerIsFirstPost(in document: Document) -> Bool {
        let scripts = document.select("script:not([src])").array().map { $0.html() }.joined(separator: "\n")
        // Read Discuz's literal desktop flag without running site JavaScript.
        if let value = HTMLTextExtractor.firstMatch(
            pattern: #"(?:^|[;\r\n])\s*(?:var\s+)?isfirstpost\s*=\s*([01])\s*;"#, in: scripts
        )?.dropFirst().first {
            return value == "1"
        }
        // The touch template exposes subject inputs on replies too, but only
        // first-post editors bind subject validation. Unknown editors stay read-only.
        return HTMLTextExtractor.firstMatch(
            pattern: #"\$\(\s*['"]#needsubject['"]\s*\)\s*\.\s*on\s*\(\s*['"]keyup input['"]"#, in: scripts
        ) != nil
    }

    private static func fieldLabel(_ control: Element, form: Element) -> String {
        let name = control.attr("name")
        if let key = labelKeys[name] { return L10n.string(key) }
        let id = control.id()
        if !id.isEmpty, let label = form.select("label").first(where: { $0.attr("for") == id })?.text().nilIfBlank { return label }
        if let label = control.parents().first(where: { $0.tagName() == "label" })?.text().nilIfBlank { return label }
        if let label = control.attr("aria-label").nilIfBlank ?? control.attr("placeholder").nilIfBlank ?? control.attr("title").nilIfBlank { return label }
        if let row = control.parents().first(where: { $0.tagName() == "tr" }),
           let label = row.selectFirst("th")?.text().nilIfBlank { return label }
        if control.attr("type").lowercased() == "file" { return L10n.string("forum.native.attachments") }
        return name
    }

    private static let labelKeys: [String: String] = [
        "subject": "forum.native.subject", "message": "forum.native.message", "readperm": "forum.native.read_permission",
        "tags": "forum.native.tags", "tag": "forum.native.tags", "typeid": "forum.native.category",
        "classid": "forum.native.category", "friend": "forum.native.privacy", "password": "forum.native.password",
        "target_names": "forum.native.target_names", "polloptions": "forum.native.poll_options",
        "reason": "forum.native.reason", "description": "forum.native.description",
        "Filedata": "forum.native.attachments", "filedata": "forum.native.attachments",
        "usesig": "forum.native.use_signature", "hiddenreplies": "forum.native.hidden_replies",
        "ordertype": "forum.native.reply_order", "allownoticeauthor": "forum.native.notify_replies",
        "noreply": "forum.native.disable_replies", "makefeed": "forum.native.publish_feed",
        "htmlon": "forum.native.allow_html", "parseurloff": "forum.native.disable_link_parsing",
        "smileyoff": "forum.native.disable_emoticons", "bbcodeoff": "forum.native.disable_bbcode",
        "imgcontent": "forum.native.download_remote_images"
    ]

    private static func continuationURL(document: Document, root: Element, baseURL: URL) -> URL? {
        if let link = root.selectFirst("#messagetext a[href], .jump_c a[href], .showmessage a[href]"),
           let url = resolvedURL(link.attr("href"), baseURL: baseURL) { return url }
        // A refresh is exposed as an explicit native link, never executed. It
        // can lead to another account action, even after a successful POST.
        for meta in document.select("meta[http-equiv]") where meta.attr("http-equiv").lowercased() == "refresh" {
            let parts = meta.attr("content").split(separator: ";", maxSplits: 1)
            guard parts.count == 2, let equals = parts[1].firstIndex(of: "=") else { continue }
            let raw = parts[1][parts[1].index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            if let url = resolvedURL(raw, baseURL: baseURL) { return url }
        }
        return nil
    }

    private static func resolvedURL(_ raw: String, baseURL: URL) -> URL? {
        guard let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func resolveReferences(in root: Element, baseURL: URL) {
        for element in root.select("a[href], img") {
            for attribute in ["href", "src", "file", "zoomfile"] where element.hasAttribute(attribute) {
                let url = resolvedURL(element.attr(attribute), baseURL: baseURL)
                element.setAttribute(attribute, value: url?.absoluteString ?? "")
            }
        }
    }

    private static func resolveComposerTabs(in document: Document, pageURL: URL) {
        let pageItems = URLComponents(url: pageURL, resolvingAgainstBaseURL: true)?.queryItems ?? []
        guard pageURL.path == "/forum.php", pageItems.contains(where: { $0.name == "mod" && $0.value == "post" }) else { return }
        // Discuz's new-thread tabs use a literal switchpost URL instead of an
        // href. Extract only that known signature; never evaluate JavaScript.
        let pattern = #"^\s*(?:return\s+)?switchpost\(['"](forum\.php\?[^'"]+)['"]\)\s*;?\s*(?:return false;?)?\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        for link in document.select("a[onclick]") {
            let source = link.attr("onclick")
            guard let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  let range = Range(match.range(at: 1), in: source),
                  let url = resolvedURL(String(source[range]), baseURL: pageURL),
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { continue }
            var items = parts.queryItems ?? []
            guard items.contains(where: { $0.name == "mod" && $0.value == "post" }),
                  items.contains(where: { $0.name == "action" && $0.value == "newthread" }) else { continue }
            if !items.contains(where: { $0.name == "fid" }), let fid = pageItems.first(where: { $0.name == "fid" }) { items.append(fid) }
            parts.queryItems = items
            link.setAttribute("href", value: parts.url?.absoluteString ?? "")
            link.setAttribute("data-native-composer-tab", value: "true")
        }
    }
}

private extension Element {
    // Element.text() collapses whitespace for display; an editor must preserve
    // the exact line breaks and indentation of the submitted source instead.
    var textareaValue: String { getChildNodes().map { $0.text() }.joined() }
}
