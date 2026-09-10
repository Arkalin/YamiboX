import Foundation

public struct ForumFormValue: Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct ForumForm: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case standard
        case thread
        case blog
    }

    public let id: String
    public let title: String
    public let actionURL: URL
    public let method: String
    public let kind: Kind
    public let fields: [ForumFormField]
    public let hiddenValues: [ForumFormValue]
    public let buttons: [ForumFormButton]
    public let instructions: [ForumThreadContentBlock]
    public let isDestructive: Bool

    public init(
        id: String, title: String, actionURL: URL, method: String = "POST", kind: Kind = .standard,
        fields: [ForumFormField] = [], hiddenValues: [ForumFormValue] = [],
        buttons: [ForumFormButton] = [], instructions: [ForumThreadContentBlock] = [], isDestructive: Bool = false
    ) {
        self.id = id
        self.title = title
        self.actionURL = actionURL
        self.method = method
        self.kind = kind
        self.fields = fields
        self.hiddenValues = hiddenValues
        self.buttons = buttons
        self.instructions = instructions
        self.isDestructive = isDestructive
    }

    public var initialValues: [String: [String]] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.initialValues) })
    }

    /// HTML successful-controls semantics: unchecked controls and unselected
    /// options are absent, repeated field names remain repeated, and only the
    /// tapped submit button contributes its name/value.
    public func submissionValues(
        values: [String: [String]], buttonID: String
    ) throws -> [ForumFormValue] {
        guard let button = buttons.first(where: { $0.id == buttonID }),
              ForumWebPagePolicy.requiresForumHandling(actionURL), ["GET", "POST"].contains(method) else {
            throw ForumPageError.invalidForm
        }
        var result = hiddenValues
        for field in fields {
            guard field.kind != .file else { continue }
            let selected = field.isReadOnly ? field.initialValues : (values[field.id] ?? field.initialValues)
            guard field.kind == .multipleChoice || selected.count <= 1 else { throw ForumPageError.invalidForm }
            if field.isRequired && (selected.isEmpty || selected.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })) {
                throw ForumPageError.requiredField(field.label)
            }
            if let maxLength = field.maxLength, selected.contains(where: { $0.count > maxLength }) {
                throw ForumPageError.fieldTooLong(field.label, maxLength)
            }
            if field.kind == .choice || field.kind == .multipleChoice || field.kind == .toggle {
                let permitted = Set(field.options.map(\.value))
                guard selected.allSatisfy({ permitted.contains($0) }) else { throw ForumPageError.invalidForm }
            }
            result.append(contentsOf: selected.map { ForumFormValue(name: field.name, value: $0) })
        }
        for override in button.values {
            result.removeAll { $0.name == override.name }
            result.append(override)
        }
        if kind == .thread {
            result.removeAll { $0.name == "wysiwyg" }
            result.append(ForumFormValue(name: "wysiwyg", value: "0"))
        }
        if kind == .blog {
            let privacy = result.first { $0.name == "friend" }?.value
            if privacy == "4", result.first(where: { $0.name == "password" })?.value.isEmpty != false {
                throw ForumPageError.requiredField(L10n.string("forum.native.password"))
            }
            if privacy == "2", result.first(where: { $0.name == "target_names" })?.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw ForumPageError.requiredField(L10n.string("forum.native.target_names"))
            }
        }
        return result
    }
}

public struct ForumFormField: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case text, multiline, password, email, number, choice, multipleChoice, toggle, file
    }

    public let id: String
    public let name: String
    public let label: String
    public let kind: Kind
    public let initialValues: [String]
    public let options: [ForumFormOption]
    public let isRequired: Bool
    public let isReadOnly: Bool
    public let maxLength: Int?

    public init(
        id: String, name: String, label: String, kind: Kind = .text, initialValues: [String] = [""],
        options: [ForumFormOption] = [], isRequired: Bool = false, isReadOnly: Bool = false, maxLength: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.label = label
        self.kind = kind
        self.initialValues = initialValues
        self.options = options
        self.isRequired = isRequired
        self.isReadOnly = isReadOnly
        self.maxLength = maxLength
    }
}

public struct ForumFormOption: Identifiable, Equatable, Sendable {
    public let value: String
    public let label: String
    public var id: String { value }

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

public struct ForumFormButton: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let values: [ForumFormValue]

    public init(id: String, title: String, values: [ForumFormValue] = []) {
        self.id = id
        self.title = title
        self.values = values
    }
}
