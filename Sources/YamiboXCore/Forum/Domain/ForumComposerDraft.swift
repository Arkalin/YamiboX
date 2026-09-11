import CryptoKit
import Foundation

public struct ForumComposerDraftAttachment: Equatable, Codable, Sendable, Identifiable {
    public let id: UUID
    public var uploadID: String?
    public var name: String
    public var mimeType: String
    public var isImage: Bool
    public var resourceID: UUID?
    public var fieldName: String?
    public var description: String
    public var anchor: ForumComposerSelection?
    public var inserted: Bool

    public init(id: UUID = UUID(), uploadID: String? = nil, name: String, mimeType: String, isImage: Bool,
                resourceID: UUID? = nil, fieldName: String? = nil, description: String = "", anchor: ForumComposerSelection? = nil, inserted: Bool = false) {
        self.id = id; self.uploadID = uploadID; self.name = name; self.mimeType = mimeType; self.isImage = isImage
        self.resourceID = resourceID; self.fieldName = fieldName; self.description = description; self.anchor = anchor; self.inserted = inserted
    }

    public var uploadedAttachment: ForumUploadedAttachment? {
        guard let uploadID, let value = Int(uploadID), value > 0 else { return nil }
        let tag = isImage ? "attachimg" : "attach"
        return .init(id: uploadID, name: name, markup: "[\(tag)]\(uploadID)[/\(tag)]",
                     values: [.init(name: "attachnew[\(uploadID)][description]", value: description)])
    }
}

public struct ForumComposerDraft: Equatable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let accountUID: String
    public var target: ForumComposerTarget
    public var fields: [String: [String]]
    public var sourceMode: Bool
    public var selection: ForumComposerSelection
    public var attachments: [ForumComposerDraftAttachment]
    public var baseline: String
    public var revision: Int64
    public var updatedAt: Date
    public var serverDraftSaved: Bool
    public var title: String { fields["subject"]?.first ?? "" }
    public var source: String { fields["message"]?.first ?? "" }

    public init(id: UUID = UUID(), accountUID: String, target: ForumComposerTarget, fields: [String: [String]],
                sourceMode: Bool = false, selection: ForumComposerSelection = .init(), attachments: [ForumComposerDraftAttachment] = [],
                baseline: String = "", revision: Int64 = 1, updatedAt: Date = .now, serverDraftSaved: Bool = false) {
        self.id = id; self.accountUID = accountUID; self.target = target
        self.fields = fields.filter { ForumComposerDraftFields.isRestorable($0.key) }
        self.sourceMode = sourceMode; self.selection = selection; self.attachments = attachments
        self.baseline = baseline; self.revision = revision; self.updatedAt = updatedAt; self.serverDraftSaved = serverDraftSaved
    }

    public static func fingerprint(form: ForumForm) -> String {
        let data = (try? JSONEncoder.sorted.encode(ForumComposerDraftFields.snapshot(form: form, values: form.initialValues))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ForumComposerDraftFields {
    private static let names: Set<String> = [
        "subject", "message", "typeid", "readperm", "tags", "tag", "usesig", "hiddenreplies", "ordertype", "allownoticeauthor",
        "noreply", "makefeed", "adddynamic", "parseurloff", "smileyoff", "bbcodeoff", "imgcontent", "htmlon",
        "polloption", "polloptions", "maxchoices", "expiration", "visiblepoll", "overt", "price", "rewardprice"
    ]

    public static func isRestorable(_ name: String) -> Bool {
        names.contains(name) || name.hasPrefix("polloption[") && name.hasSuffix("]")
    }

    public static func snapshot(form: ForumForm, values: [String: [String]]) -> [String: [String]] {
        guard form.kind == .thread else { return [:] }
        var result: [String: [String]] = [:]
        for field in form.fields where isRestorable(field.name) && !field.isReadOnly && field.kind != .password && field.kind != .file {
            result[field.name, default: []] += values[field.id] ?? field.initialValues
        }
        return result
    }

    public static func restoring(_ snapshot: [String: [String]], into form: ForumForm) -> [String: [String]] {
        var result = form.initialValues
        var remaining = snapshot
        for field in form.fields where isRestorable(field.name) && !field.isReadOnly && field.kind != .password && field.kind != .file {
            guard let values = remaining[field.name] else { continue }
            let selected: [String]
            if field.kind == .multipleChoice { selected = values; remaining[field.name] = [] }
            else { selected = Array(values.prefix(1)); remaining[field.name] = Array(values.dropFirst()) }
            if [.choice, .multipleChoice, .toggle].contains(field.kind) {
                let permitted = Set(field.options.map(\.value))
                guard selected.allSatisfy(permitted.contains) else { continue }
            }
            result[field.id] = selected
        }
        return result
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}

public enum ForumComposerDraftError: LocalizedError, Equatable, Sendable {
    case conflict, deleted, accountMismatch, reset, missingResource, invalidDraft
    public var errorDescription: String? {
        switch self {
        case .conflict: L10n.string("forum.composer.draft_conflict")
        case .deleted: L10n.string("forum.composer.draft_deleted")
        case .accountMismatch: L10n.string("forum.composer.account_changed")
        case .reset: L10n.string("forum.composer.drafts_reset")
        case .missingResource: L10n.string("forum.composer.missing_resource")
        case .invalidDraft: L10n.string("forum.composer.invalid_draft")
        }
    }
}
