import Foundation

public enum ForumPagePurpose: Equatable, Sendable {
    case postEditor
    case blogEditor
    case actionForm
    case document

    public init(url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value: (String) -> String = { name in items.first { $0.name == name }?.value ?? "" }
        if ForumWebPagePolicy.requiresConfirmationToLoad(url) {
            self = .actionForm
        } else if url.path == "/forum.php", value("mod") == "post",
                  ["newthread", "reply", "edit"].contains(value("action")) {
            self = .postEditor
        } else if url.path == "/home.php", value("mod") == "spacecp", value("ac") == "blog" {
            self = .blogEditor
        } else if (url.path == "/home.php" && value("mod") == "spacecp")
                    || (url.path == "/forum.php" && ["post", "modcp"].contains(value("mod")))
                    || (url.path == "/forum.php" && value("mod") == "misc" && ["rate", "report"].contains(value("action")))
                    || (url.path == "/member.php" && value("mod") == "register")
                    || url.path == "/search.php" {
            self = .actionForm
        } else {
            self = .document
        }
    }
}

public enum ForumPostEditorMode: String, Equatable, Sendable {
    case newThread
    case reply
    case edit

    public init?(url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch items.first(where: { $0.name == "action" })?.value {
        case "newthread": self = .newThread
        case "reply": self = .reply
        case "edit": self = .edit
        default: return nil
        }
    }
}
