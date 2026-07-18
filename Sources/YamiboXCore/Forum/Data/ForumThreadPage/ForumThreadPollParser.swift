import Foundation

/// Parses poll ("投票") data: the poll block embedded in a post and the
/// poll-voters popout (options, selected option, voter list).
enum ForumThreadPollParser {
    static func poll(in container: Element, body: Element) -> ForumThreadPoll? {
        let candidates = (
            body.selectAll("#poll, .poll, .polls, .pcht") + container.selectAll("#poll, .poll, .polls, .pcht")
        ).deduplicatedByDOMIdentity()
        guard let pollElement = candidates.first(where: { element in
            !element.selectAll("input[type=radio], input[type=checkbox]").isEmpty
                || element.normalizedText().contains("%")
        }) else {
            return nil
        }

        let inputElements = pollElement.selectAll("input[type=radio], input[type=checkbox]")
        let isMultipleChoice = inputElements.contains { $0.attr("type").lowercased() == "checkbox" }
        let status: ForumThreadPollStatus = inputElements.isEmpty
            ? .voted
            : .notVoted
        let type: ForumThreadPollType = inputElements.isEmpty
            ? .unknown
            : (isMultipleChoice ? .multipleChoice : .singleChoice)
        let options = pollOptions(in: pollElement, inputs: inputElements)
        guard !options.isEmpty else { return nil }

        return ForumThreadPoll(
            title: pollTitle(in: pollElement) ?? L10n.string("forum.thread.poll"),
            endTimeText: pollEndTime(in: pollElement),
            type: type,
            status: status,
            options: options
        )
    }

    static func voterOptions(
        in document: Document,
        requestedOptionID: String?
    ) -> [ForumThreadPollVoterOption] {
        var options: [ForumThreadPollVoterOption] = []
        var seen: Set<String> = []

        for option in document.selectAll("select option[value], option[value]") {
            guard let id = option.attrText("value"),
                  let name = option.normalizedText().nilIfBlank,
                  seen.insert(id).inserted else { continue }
            options.append(ForumThreadPollVoterOption(id: id, name: name))
        }

        for link in document.selectAll("a[href*='polloptionid=']") {
            guard let url = link.attrURL("href"),
                  let id = url.queryItemValue("polloptionid"),
                  seen.insert(id).inserted else {
                continue
            }
            let name = link.normalizedText().nilIfBlank ?? id
            options.append(ForumThreadPollVoterOption(id: id, name: name))
        }

        if let requestedOptionID, !seen.contains(requestedOptionID) {
            options.insert(ForumThreadPollVoterOption(id: requestedOptionID, name: requestedOptionID), at: 0)
        }

        return options
    }

    static func selectedOptionID(in document: Document) -> String? {
        if let value = document.selectFirst("select option[selected]")?.attrText("value") {
            return value
        }
        for selector in ["a.a[href*='polloptionid=']", "a.xw1[href*='polloptionid=']", "strong a[href*='polloptionid=']"] {
            if let value = document.firstURL(selector)?.queryItemValue("polloptionid") {
                return value
            }
        }
        return nil
    }

    static func voters(in document: Document) -> [BlogReaderUser] {
        var voters: [BlogReaderUser] = []
        var seen: Set<String> = []

        for link in document.selectAll("a[href*='uid='], a[href*='space-uid-']") {
            let name = link.normalizedText().nilIfBlank
            let uid = ForumUserIDParser.userID(fromHref: link.attr("href"))
            guard let name, uid != nil || !name.isEmpty else { continue }
            let key = uid ?? name
            guard seen.insert(key).inserted else { continue }
            voters.append(BlogReaderUser(uid: uid, name: name, avatarURL: nil))
        }

        return voters
    }

    private static func pollOptions(
        in pollElement: Element,
        inputs: [Element]
    ) -> [ForumThreadPollOption] {
        if !inputs.isEmpty {
            return inputs.enumerated().compactMap { index, input in
                let row = nearestAncestor(
                    of: input,
                    matching: { element in
                        let tag = element.tagName().lowercased()
                        return tag == "tr" || tag == "li" || tag == "p" || element.hasClass("polloption")
                    }
                ) ?? input.parent()
                let rawText = (row ?? input).text()
                let inputValue = input.attr("value")
                let optionText = optionTitle(from: rawText)
                    ?? inputValue.nilIfBlank
                    ?? "\(index + 1)"
                return ForumThreadPollOption(
                    id: inputValue.nilIfBlank ?? "\(index)",
                    title: optionText,
                    voteCount: voteCount(in: rawText),
                    percentage: percentage(in: rawText),
                    isSelected: !input.attr("checked").isEmpty
                )
            }
        }

        let rows = pollElement.selectAll("tr, li, p")
        return rows.enumerated().compactMap { index, row in
            let text = row.normalizedText()
            guard text.contains("%"),
                  let title = optionTitle(from: text) else {
                return nil
            }
            return ForumThreadPollOption(
                id: "\(index)",
                title: title,
                voteCount: voteCount(in: text),
                percentage: percentage(in: text)
            )
        }
    }

    private static func pollTitle(in pollElement: Element) -> String? {
        if let text = pollElement.firstText(anyOf: ["h3", "h4", ".polltitle", ".xs2", ".pcht h4", "caption"]) {
            return text
        }
        let text = pollElement.normalizedText()
        return text
            .components(separatedBy: CharacterSet(charactersIn: "。.!?？\n"))
            .first?
            .nilIfBlank
    }

    private static func pollEndTime(in pollElement: Element) -> String? {
        for selector in ["p", ".xg1", ".polltime", ".poll_time"] {
            for element in pollElement.selectAll(selector) {
                let text = element.normalizedText()
                guard text.contains("结束")
                    || text.contains("結束")
                    || text.contains("截止")
                    || text.contains("投票截止") else {
                    continue
                }
                if let value = HTMLTextExtractor.firstMatch(
                    pattern: #"(?:结束时间|結束時間|截止时间|截止時間|投票截止)[:：]?\s*(.+)$"#,
                    in: text
                )?
                    .dropFirst()
                    .first?
                    .nilIfBlank {
                    return value
                }
            }
        }

        let text = pollElement.normalizedText()
        return HTMLTextExtractor.firstMatch(
            pattern: #"(结束时间|結束時間|截止时间|截止時間|投票截止)[:：]?\s*([0-9]{4}[-/年][^。；;\n ]+(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?)"#,
            in: text
        )?
            .dropFirst()
            .dropFirst()
            .first?
            .nilIfBlank
    }

    private static func optionTitle(from text: String) -> String? {
        let value = text
            .replacingOccurrences(of: #"\d+(?:\.\d+)?%\s*(?:\(\d+\))?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\d+\s*(?:票|人|votes?)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"^\s*[\[\]☑✓○●•\-\d.、]+\s*"#, with: "", options: .regularExpression)
        return value.htmlNormalized.nilIfBlank
    }

    private static func percentage(in text: String) -> Double? {
        HTMLTextExtractor.firstMatch(pattern: #"(\d+(?:\.\d+)?)\s*%"#, in: text)?
            .dropFirst()
            .first
            .flatMap(Double.init)
    }

    private static func voteCount(in text: String) -> Int? {
        HTMLTextExtractor.firstMatch(pattern: #"(\d+)\s*(?:票|人|votes?)"#, in: text)?
            .dropFirst()
            .first
            .flatMap(Int.init)
    }

    private static func nearestAncestor(
        of element: Element,
        matching predicate: (Element) -> Bool
    ) -> Element? {
        var current = element.parent()
        while let candidate = current {
            if predicate(candidate) {
                return candidate
            }
            current = candidate.parent()
        }
        return nil
    }
}
