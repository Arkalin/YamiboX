import Foundation

public struct ForumAttachmentFile: Equatable, Sendable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        // Content-Disposition is remote input, never a filesystem path.
        let component = URL(fileURLWithPath: name).lastPathComponent
        self.name = component.isEmpty || component == "." || component == ".." ? "attachment" : String(component.prefix(180))
        self.data = data
    }
}

public struct ForumUploadConfiguration: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case threadImage, threadAttachment, blogImage }
    public let id: String
    public let url: URL
    public let kind: Kind
    public let values: [ForumFormValue]
    public let maximumBytes: Int
    public let extensions: [String]

    public init(id: String, url: URL, kind: Kind, values: [ForumFormValue], maximumBytes: Int, extensions: [String]) {
        self.id = id
        self.url = url
        self.kind = kind
        self.values = values
        self.maximumBytes = maximumBytes
        self.extensions = extensions
    }
}

public struct ForumUploadedAttachment: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let markup: String
    public let values: [ForumFormValue]

    public init(id: String, name: String, markup: String, values: [ForumFormValue]) {
        self.id = id
        self.name = name
        self.markup = markup
        self.values = values
    }
}

public struct ForumFormFile: Equatable, Sendable {
    public let fieldName: String
    public let file: ForumAttachmentFile
    public let mimeType: String

    public init(fieldName: String, file: ForumAttachmentFile, mimeType: String) {
        self.fieldName = fieldName
        self.file = file
        self.mimeType = mimeType
    }
}
