import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public actor CustomBackgroundImageStore {
    public enum Scope: String, Sendable {
        case favorites = "favorite-background"
        case launch = "launch-background"
    }
    public static let defaultJPEGQuality = 0.88
    public static let defaultMaximumLongEdgePixels = 4096

    private let fileManager: FileManager
    private let baseDirectory: URL

    public init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil,
        scope: Scope = .favorites
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory ?? Self.directory(scope: scope, fileManager: fileManager)
    }

    public nonisolated static func directory(scope: Scope, rootDirectory: URL? = nil, fileManager: FileManager = .default) -> URL {
        (rootDirectory ?? YamiboDatabase.defaultRootDirectory(fileManager: fileManager))
            .appendingPathComponent(scope.rawValue, isDirectory: true)
    }

    public func loadData(imageID: String?) async -> Data? {
        guard let imageID, !imageID.isEmpty else { return nil }
        do {
            return try Data(contentsOf: imageURL(for: imageID))
        } catch {
            YamiboLog.persistence.warning("Failed to read custom background image data for id \(imageID, privacy: .public): \(error)")
            return nil
        }
    }

    public func save(_ data: Data, imageID: String) async throws {
        try ensureDirectoryExists()
        try data.write(to: imageURL(for: imageID), options: [.atomic])
    }

    public func delete(imageID: String?) async throws {
        guard let imageID, !imageID.isEmpty else { return }
        let url = imageURL(for: imageID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    public func deleteAll() async throws {
        guard fileManager.fileExists(atPath: baseDirectory.path) else { return }
        try fileManager.removeItem(at: baseDirectory)
    }

    public func prune(keeping imageID: String?) async throws {
        guard fileManager.fileExists(atPath: baseDirectory.path) else { return }
        let keepFileName = imageID.map(fileName(for:))
        let urls = try fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil
        )
        for url in urls where url.lastPathComponent != keepFileName {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                YamiboLog.persistence.warning("Failed to remove stale custom background image \(url.lastPathComponent, privacy: .public): \(error)")
            }
        }
    }

    public func fileExists(imageID: String?) async -> Bool {
        guard let imageID, !imageID.isEmpty else { return false }
        return fileManager.fileExists(atPath: imageURL(for: imageID).path)
    }

    private func ensureDirectoryExists() throws {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
    }

    private func imageURL(for imageID: String) -> URL {
        baseDirectory.appendingPathComponent(fileName(for: imageID), isDirectory: false)
    }

    private func fileName(for imageID: String) -> String {
        "\(imageID).jpg"
    }
}

public enum CustomBackgroundImageProcessor {
    public static func normalizedJPEGData(
        from sourceData: Data,
        maximumLongEdgePixels: Int = CustomBackgroundImageStore.defaultMaximumLongEdgePixels,
        compressionQuality: Double = CustomBackgroundImageStore.defaultJPEGQuality
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw YamiboPersistenceError(context: "Invalid image data")
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximumLongEdgePixels),
            kCGImageSourceShouldCache: false
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw YamiboPersistenceError(context: "Invalid image data")
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw YamiboPersistenceError(context: "Unable to create JPEG destination")
        }

        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: CustomBackgroundSettings.clampJPEGQuality(compressionQuality)
        ]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw YamiboPersistenceError(context: "Unable to write JPEG data")
        }

        return output as Data
    }
}

private extension CustomBackgroundSettings {
    static func clampJPEGQuality(_ value: Double) -> Double {
        guard value.isFinite else { return CustomBackgroundImageStore.defaultJPEGQuality }
        return min(1, max(0, value))
    }
}
