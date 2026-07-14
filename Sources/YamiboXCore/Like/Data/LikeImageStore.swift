import Foundation

/// Stores retained image bytes for image Like Items, keyed by the owning
/// `LikeItem.id`. Unlike `FavoriteBackgroundImageStore`, bytes are kept as
/// captured (no JPEG re-encoding): a liked image is user-retained content,
/// not regenerable decoration.
public actor LikeImageStore {
    private let fileManager: FileManager
    private let baseDirectory: URL

    public init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("YamiboX", isDirectory: true)
            .appendingPathComponent("like-images", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("like-images", isDirectory: true)
    }

    public func save(_ data: Data, id: String, sourceURL: URL?) async throws {
        guard !id.isEmpty else { return }
        try ensureDirectoryExists()
        try? removeExistingFiles(id: id)
        try data.write(to: fileURL(id: id, sourceURL: sourceURL), options: [.atomic])
    }

    public func loadData(id: String) async -> Data? {
        guard let url = existingFileURL(id: id) else { return nil }
        return try? Data(contentsOf: url)
    }

    public func delete(id: String) async throws {
        guard !id.isEmpty else { return }
        try removeExistingFiles(id: id)
    }

    public func deleteAll() async throws {
        guard fileManager.fileExists(atPath: baseDirectory.path) else { return }
        try fileManager.removeItem(at: baseDirectory)
    }

    public func fileExists(id: String) async -> Bool {
        existingFileURL(id: id) != nil
    }

    private func ensureDirectoryExists() throws {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
    }

    private func fileURL(id: String, sourceURL: URL?) -> URL {
        baseDirectory.appendingPathComponent(fileName(id: id, sourceURL: sourceURL), isDirectory: false)
    }

    private func fileName(id: String, sourceURL: URL?) -> String {
        "\(id).\(sanitizedExtension(for: sourceURL))"
    }

    private func sanitizedExtension(for sourceURL: URL?) -> String {
        let rawExtension = sourceURL?.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sanitized = rawExtension.replacingOccurrences(of: #"[^A-Za-z0-9]"#, with: "", options: .regularExpression)
        return sanitized.isEmpty ? "bin" : sanitized
    }

    private func existingFileURL(id: String) -> URL? {
        guard !id.isEmpty,
              let urls = try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else {
            return nil
        }
        return urls.first { $0.deletingPathExtension().lastPathComponent == id }
    }

    private func removeExistingFiles(id: String) throws {
        guard let urls = try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in urls where url.deletingPathExtension().lastPathComponent == id {
            try? fileManager.removeItem(at: url)
        }
    }
}
