import CryptoKit
import Foundation
import ImageIO

/// Retained original artwork, not an evictable cache. All access is serialized
/// by ContentCoverStore, including reference checks and clear generations.
struct ContentCoverImageStore: Sendable {
    let directory: URL

    var hasMigratedOrdinaryImages: Bool {
        FileManager.default.fileExists(atPath: migrationMarker.path)
    }

    func finishOrdinaryImageMigration() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: migrationMarker, options: .atomic)
    }

    func data(for url: URL) throws -> Data? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL(for: url))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        guard Self.isDecodable(data) else {
            // A bad retained response must not permanently shadow a later
            // successful request. Keep IO errors visible if removal fails.
            try FileManager.default.removeItem(at: fileURL(for: url))
            return nil
        }
        return data
    }

    func containsImage(for url: URL) throws -> Bool {
        try data(for: url) != nil
    }

    func save(_ data: Data, for url: URL) throws {
        guard Self.isDecodable(data) else { throw YamiboError.invalidImageData }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: url), options: .atomic)
    }

    private static func isDecodable(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetStatus(source) == .statusComplete,
            CGImageSourceGetCount(source) > 0 else { return false }
        // Decode the cover's first frame, not just its header or an embedded
        // thumbnail. Bound decoded memory and retain the original bytes.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCache: false
        ]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil else { return false }
        return CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
    }

    func retainOnly(_ urls: Set<URL>) throws {
        let names = Set(urls.map { fileURL(for: $0).lastPathComponent })
        for file in try files() where !names.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }

    func deleteAll() throws {
        // Per-file deletion makes a partially failed clear safely retryable.
        for file in try files() {
            try FileManager.default.removeItem(at: file)
        }
    }

    func usageBytes() throws -> Int {
        try files().reduce(0) { total, file in
            let values = try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            return total + (values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
    }

    private func files() throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent != migrationMarker.lastPathComponent }
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
    }

    private func fileURL(for url: URL) -> URL {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    // Keep the marker across cover clears: newly cached reader copies must
    // never be mistaken for pre-separation cover data on the next launch.
    private var migrationMarker: URL { directory.appendingPathComponent(".ordinary-image-migration-v1") }
}
