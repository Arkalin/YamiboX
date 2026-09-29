import CryptoKit
import Foundation

/// Durable user files, separate from regenerable reader caches.
public actor ReaderFontFileStore {
    public static var defaultDirectory: URL {
        YamiboDatabase.defaultRootDirectory().appendingPathComponent("ReaderFonts", isDirectory: true)
    }

    private let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public init(directory: URL = ReaderFontFileStore.defaultDirectory) { self.directory = directory }

    public func load() throws -> [ReaderImportedFontFile] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        return try JSONDecoder().decode([ReaderImportedFontFile].self, from: Data(contentsOf: indexURL))
    }

    public func fileURL(_ relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, relativePath == (relativePath as NSString).lastPathComponent,
              relativePath != ".", relativePath != ".." else { throw CocoaError(.fileReadInvalidFileName) }
        return directory.appendingPathComponent(relativePath)
    }

    public func stage(_ source: URL) throws -> (id: String, relativePath: String, url: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        guard ["ttf", "otf", "ttc", "otc"].contains(ext) else { throw CocoaError(.fileReadUnknown) }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        // Reimport can repair a missing file even if its external extension changed.
        let path = try load().first(where: { $0.id == id })?.relativePath ?? "\(id).\(ext)"
        let url = try fileURL(path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        return (id, path, url)
    }

    public func save(_ files: [ReaderImportedFontFile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(files).write(to: indexURL, options: .atomic)
    }

    public func remove(_ relativePath: String) throws {
        let url = try fileURL(relativePath)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func reset() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
