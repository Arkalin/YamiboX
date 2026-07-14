import Foundation

enum YamiboLoginFormParser {
    static func parse(_ html: String) throws -> YamiboLoginForm {
        let document = try KannaSoup.parse(html)
        guard let form = try document.select("form#loginform").first() else {
            throw YamiboError.loginFormUnavailable
        }

        let action = try form.attr("action")
        guard let actionURL = HTMLTextExtractor.absoluteURL(from: action) else {
            throw YamiboError.loginFormUnavailable
        }

        let hiddenFields = try form.select("input[type=hidden]").compactMap { input -> (String, String)? in
            let name = try input.attr("name").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let value = try input.attr("value")
            return (name, value)
        }

        let questions = try form.select("select[name=questionid] option").compactMap { option -> YamiboLoginQuestion? in
            let id = try option.attr("value").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = try option.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !title.isEmpty else { return nil }
            return YamiboLoginQuestion(id: id, title: title)
        }

        return YamiboLoginForm(
            actionURL: actionURL,
            hiddenFields: hiddenFields,
            questions: questions.isEmpty ? YamiboLoginQuestion.defaultQuestions : questions
        )
    }
}
