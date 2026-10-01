import Foundation

/// Stores retained image bytes for image Like Items, keyed by the owning
/// `LikeItem.id`. Unlike `FavoriteBackgroundImageStore`, bytes are kept as
/// captured (no JPEG re-encoding): a liked image is user-retained content,
/// not regenerable decoration.
public actor LikeImageStore: LikeImageWriting {
    private let fileManager: FileManager
    private let baseDirectory: URL
    private struct DirectoryStamp: Equatable {
        let modifiedAt: Date?
        let fileNumber: UInt64?
    }
    private var indexedStamp: DirectoryStamp?
    private var filesByID: [String: [URL]]?

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
        defer { invalidateFileIndex() }
        let destination = fileURL(id: id, sourceURL: sourceURL)
        try data.write(to: destination, options: [.atomic])
    }

    public func loadData(id: String) async -> Data? {
        guard let url = existingFileURL(id: id) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            invalidateFileIndex()
            return nil
        }
    }

    public func delete(id: String) async throws {
        guard !id.isEmpty else { return }
        try removeExistingFiles(id: id)
    }

    public func delete(ids: [String]) async throws {
        try removeExistingFiles(ids: ids.filter { !$0.isEmpty })
    }

    public func deleteAll() async throws {
        defer { invalidateFileIndex() }
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
        guard !id.isEmpty else { return nil }
        do {
            try refreshFileIndexIfNeeded()
            guard let url = filesByID?[id]?.first else { return nil }
            if fileManager.fileExists(atPath: url.path) { return url }
            // A vanished cached file needs a fresh listing so another legacy
            // suffix can be found. Ordinary additions invalidate via the stamp.
            invalidateFileIndex()
            try refreshFileIndexIfNeeded()
            return filesByID?[id]?.first
        } catch {
            invalidateFileIndex()
            return nil
        }
    }

    private func removeExistingFiles(id: String) throws {
        try removeExistingFiles(ids: [id])
    }

    private func removeExistingFiles(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        guard fileManager.fileExists(atPath: baseDirectory.path) else {
            invalidateFileIndex()
            return
        }
        // Never claim an observed post-mutation stamp for a partial index:
        // another writer may have changed unrelated files during our deletion.
        defer { invalidateFileIndex() }
        do {
            try refreshFileIndexIfNeeded()
            for id in ids {
                for url in filesByID?[id] ?? [] {
                    try fileManager.removeItem(at: url)
                }
                filesByID?[id] = nil
            }
        } catch {
            // A partial deletion or external file change needs a fresh listing
            // on the next operation, rather than keeping stale paths.
            invalidateFileIndex()
            throw error
        }
    }

    private func directoryStamp() throws -> DirectoryStamp {
        let attributes = try fileManager.attributesOfItem(atPath: baseDirectory.path)
        return DirectoryStamp(
            modifiedAt: attributes[.modificationDate] as? Date,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private func refreshFileIndexIfNeeded() throws {
        let stamp = try? directoryStamp()
        guard filesByID == nil || stamp?.modifiedAt == nil || indexedStamp != stamp else { return }
        let urls = try fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)
        var index: [String: [URL]] = [:]
        for url in urls {
            index[url.deletingPathExtension().lastPathComponent, default: []].append(url)
        }
        // Preserve the listing's first-match order and all legacy suffixes.
        filesByID = index
        indexedStamp = stamp
    }

    private func invalidateFileIndex() {
        filesByID = nil
        indexedStamp = nil
    }

}
