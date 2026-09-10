import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers
import YamiboXCore

struct ForumUploadImage: Sendable {
    let file: ForumAttachmentFile
    let mimeType: String
    let wasConverted: Bool
}

struct ForumPickedImage: Transferable, Sendable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            guard data.count <= ForumUploadImageProcessor.maximumSourceBytes else { throw ForumPageError.fileTooLarge }
            return Self(data: data)
        }
    }
}

actor ForumUploadImageProcessor {
    static let shared = ForumUploadImageProcessor()
    static let maximumSourceBytes = 50 * 1024 * 1024

    func prepare(_ data: Data, configuration: ForumUploadConfiguration) throws -> ForumUploadImage {
        try Task.checkCancellation()
        guard data.count <= Self.maximumSourceBytes else { throw ForumPageError.fileTooLarge }
        guard configuration.kind != .threadAttachment,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source) else { throw ForumUploadImageError.invalidImage }
        guard let type = UTType(identifier as String) else { throw ForumPageError.unsupportedUpload }
        let limit = min(configuration.maximumBytes, 5 * 1024 * 1024)

        // Keep animation, transparency and existing encoding intact whenever possible.
        if type == .jpeg || type == .png || type == .gif {
            let ext = try permittedExtension(for: type, configuration: configuration)
            guard data.count <= limit else { throw ForumPageError.fileTooLarge }
            return result(data, type: type, extension: ext, wasConverted: false)
        }
        guard type == .heic || type == .heif else { throw ForumPageError.unsupportedUpload }

        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ForumUploadImageError.invalidImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(4096, max(width, height)),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw ForumUploadImageError.invalidImage
        }
        try Task.checkCancellation()
        let hasAlpha = [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo)
        let outputType: UTType
        if !hasAlpha, (try? permittedExtension(for: .jpeg, configuration: configuration)) != nil { outputType = .jpeg }
        else { outputType = .png }
        let ext = try permittedExtension(for: outputType, configuration: configuration)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, outputType.identifier as CFString, 1, nil) else {
            throw ForumUploadImageError.invalidImage
        }
        // The thumbnail transform is baked into the pixels; do not copy EXIF orientation or GPS.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ForumUploadImageError.invalidImage }
        try Task.checkCancellation()
        guard output.length <= limit else { throw ForumPageError.fileTooLarge }
        return result(output as Data, type: outputType, extension: ext, wasConverted: true)
    }

    private func permittedExtension(for type: UTType, configuration: ForumUploadConfiguration) throws -> String {
        let candidates = type == .jpeg ? ["jpg", "jpeg", "jpe"] : [type.preferredFilenameExtension ?? ""]
        guard let ext = candidates.first(where: { !$0.isEmpty && (configuration.extensions.isEmpty || configuration.extensions.contains($0)) }) else {
            throw ForumPageError.unsupportedUpload
        }
        return ext
    }

    private func result(_ data: Data, type: UTType, extension ext: String, wasConverted: Bool) -> ForumUploadImage {
        ForumUploadImage(file: .init(name: "image-\(UUID().uuidString.prefix(8)).\(ext)", data: data),
                               mimeType: type.preferredMIMEType ?? "application/octet-stream", wasConverted: wasConverted)
    }
}

enum ForumUploadImageError: LocalizedError, Equatable {
    case invalidImage

    var errorDescription: String? { L10n.string("forum.native.image_load_failed") }
}
