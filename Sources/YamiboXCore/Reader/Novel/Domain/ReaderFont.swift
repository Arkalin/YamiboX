import Foundation

public enum ReaderCuratedFont: String, Codable, CaseIterable, Sendable {
    case pingFangSC, pingFangTC, songtiSC, songtiTC, kaitiSC, kaitiTC, heitiSC, heitiTC

    public var familyName: String {
        switch self {
        case .pingFangSC: "PingFang SC"
        case .pingFangTC: "PingFang TC"
        case .songtiSC: "Songti SC"
        case .songtiTC: "Songti TC"
        case .kaitiSC: "Kaiti SC"
        case .kaitiTC: "Kaiti TC"
        case .heitiSC: "Heiti SC"
        case .heitiTC: "Heiti TC"
        }
    }

    public var title: String { L10n.string("reader.font.\(rawValue)") }
}

public enum ReaderFontSelection: Codable, Hashable, Sendable {
    case curated(ReaderCuratedFont)
    case imported(fileID: String, postScriptName: String)

    public static let standard = ReaderFontSelection.curated(.pingFangSC)

    public var stableID: String {
        switch self {
        case let .curated(font): "curated:\(font.rawValue)"
        case let .imported(fileID, name): "imported:\(fileID):\(name)"
        }
    }

    public var fileID: String? {
        guard case let .imported(fileID, _) = self else { return nil }
        return fileID
    }
}

/// Ephemeral, platform-neutral resolution. Never persisted with appearance settings.
public struct ReaderResolvedFont: Hashable, Sendable {
    public let bodyName: String
    public let boldName: String
    public let fingerprint: String
    public let isFallback: Bool

    public init(bodyName: String, boldName: String, fingerprint: String, isFallback: Bool) {
        self.bodyName = bodyName
        self.boldName = boldName
        self.fingerprint = fingerprint
        self.isFallback = isFallback
    }
}

public enum ReaderFontAvailability: Equatable, Sendable {
    case available, unavailable
}

public struct ReaderFontEntry: Identifiable, Sendable {
    public var id: ReaderFontSelection { selection }
    public let selection: ReaderFontSelection
    public let title: String
    public var availability: ReaderFontAvailability
    public let hasMissingSampleGlyphs: Bool

    public init(selection: ReaderFontSelection, title: String, availability: ReaderFontAvailability,
                hasMissingSampleGlyphs: Bool = false) {
        self.selection = selection
        self.title = title
        self.availability = availability
        self.hasMissingSampleGlyphs = hasMissingSampleGlyphs
    }
}

public struct ReaderImportedFontFace: Codable, Hashable, Sendable {
    public let postScriptName: String
    public let familyName: String
    public let displayName: String
    public let isBold: Bool

    public init(postScriptName: String, familyName: String, displayName: String, isBold: Bool) {
        self.postScriptName = postScriptName
        self.familyName = familyName
        self.displayName = displayName
        self.isBold = isBold
    }
}

public struct ReaderImportedFontFile: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let relativePath: String
    public let faces: [ReaderImportedFontFace]

    public init(id: String, relativePath: String, faces: [ReaderImportedFontFace]) {
        self.id = id
        self.relativePath = relativePath
        self.faces = faces
    }
}

@MainActor
public protocol ReaderFontLibraryServing: AnyObject {
    var entries: [ReaderFontEntry] { get }
    func prepare() async
    func resolve(_ selection: ReaderFontSelection) -> ReaderResolvedFont
    func importFiles(_ urls: [URL]) async -> [String]
    func deleteFile(_ id: String, protecting selections: Set<ReaderFontSelection>) async throws
}
