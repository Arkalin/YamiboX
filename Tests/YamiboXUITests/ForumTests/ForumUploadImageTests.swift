import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import YamiboXCore
@testable import YamiboXUI

struct ForumUploadImageTests {
    @Test(arguments: [UTType.jpeg, .png, .gif])
    func supportedImagesKeepOriginalBytesAndMatchingMIME(_ type: UTType) async throws {
        let data = try imageData(type: type, frames: type == .gif ? 2 : 1, alpha: type == .png)
        let image = try await ForumUploadImageProcessor.shared.prepare(data, configuration: configuration())
        #expect(image.file.data == data)
        #expect(image.mimeType == type.preferredMIMEType)
        #expect(!image.wasConverted)
        let source = try #require(CGImageSourceCreateWithData(image.file.data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == (type == .gif ? 2 : 1))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        if type == .png { #expect(properties[kCGImagePropertyHasAlpha] as? Bool == true) }
    }

    @Test func animatedPNGIsNotFlattened() async throws {
        let data = try imageData(type: .png, frames: 2, alpha: true)
        let image = try await ForumUploadImageProcessor.shared.prepare(data, configuration: configuration())
        #expect(image.file.data == data)
        let source = try #require(CGImageSourceCreateWithData(image.file.data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 2)
    }

    @Test func heicBecomesJPEGWithUprightPixelsAndPermittedExtension() async throws {
        let data = try imageData(type: .heic, orientation: 6)
        let image = try await ForumUploadImageProcessor.shared.prepare(data, configuration: configuration(extensions: ["jpeg"]))
        #expect(image.wasConverted)
        #expect(image.mimeType == "image/jpeg")
        #expect(image.file.name.hasSuffix(".jpeg"))
        let source = try #require(CGImageSourceCreateWithData(image.file.data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 20)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 40)
        #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func heicCanUsePNGWhenForumDoesNotAllowJPEG() async throws {
        let data = try imageData(type: .heic)
        let image = try await ForumUploadImageProcessor.shared.prepare(data, configuration: configuration(extensions: ["png"]))
        #expect(image.wasConverted)
        #expect(image.mimeType == "image/png")
        #expect(image.file.name.hasSuffix(".png"))
    }

    @Test func oversizedHEICIsDownsampledWithinDecodeBudget() async throws {
        let data = try imageData(type: .heic, width: 5000, height: 20)
        let image = try await ForumUploadImageProcessor.shared.prepare(data, configuration: configuration())
        let source = try #require(CGImageSourceCreateWithData(image.file.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 4096)
    }

    @Test func disallowedGIFAndTransparentPNGAreNotSilentlyFlattened() async throws {
        for type in [UTType.gif, .png] {
            let data = try imageData(type: type, frames: type == .gif ? 2 : 1, alpha: true)
            await #expect(throws: ForumPageError.unsupportedUpload) {
                try await ForumUploadImageProcessor.shared.prepare(data, configuration: configuration(extensions: ["jpg"]))
            }
        }
    }

    @Test func uploadSizeLimitIsCheckedForOriginalAndConvertedData() async throws {
        let data = try imageData(type: .png)
        let image = try await ForumUploadImageProcessor.shared.prepare(data, configuration: configuration(maximumBytes: data.count))
        #expect(image.file.data.count == data.count)
        await #expect(throws: ForumPageError.fileTooLarge) {
            try await ForumUploadImageProcessor.shared.prepare(data, configuration: configuration(maximumBytes: data.count - 1))
        }
        let heic = try imageData(type: .heic)
        await #expect(throws: ForumPageError.fileTooLarge) {
            try await ForumUploadImageProcessor.shared.prepare(heic, configuration: configuration(maximumBytes: 1))
        }
        var oversized = data
        oversized.append(Data(count: 5 * 1024 * 1024))
        await #expect(throws: ForumPageError.fileTooLarge) {
            try await ForumUploadImageProcessor.shared.prepare(oversized, configuration: configuration(maximumBytes: 10 * 1024 * 1024))
        }
    }

    @Test func invalidAndUnsupportedDataAreRejectedBeforeUpload() async throws {
        for data in [Data(), Data("not an image".utf8)] {
            await #expect(throws: ForumUploadImageError.invalidImage) {
                try await ForumUploadImageProcessor.shared.prepare(data, configuration: configuration())
            }
        }
        let tiff = try imageData(type: .tiff)
        await #expect(throws: ForumPageError.unsupportedUpload) {
            try await ForumUploadImageProcessor.shared.prepare(tiff, configuration: configuration(extensions: []))
        }
    }

    private func configuration(maximumBytes: Int = 5 * 1024 * 1024, extensions: [String] = ["jpg", "jpeg", "png", "gif"]) -> ForumUploadConfiguration {
        .init(id: "image", url: URL(string: "https://bbs.yamibo.com/misc.php?mod=swfupload&operation=upload")!,
              kind: .threadImage, values: [.init(name: "hash", value: "offline-only")], maximumBytes: maximumBytes, extensions: extensions)
    }

    private func imageData(type: UTType, frames: Int = 1, alpha: Bool = false, orientation: Int = 1,
                           width: Int = 40, height: Int = 20) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil))
        for index in 0 ..< frames {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue))
            context.setFillColor(CGColor(red: CGFloat(index), green: 0.5, blue: 0.25, alpha: alpha ? 0.5 : 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try #require(context.makeImage())
            let properties: [CFString: Any] = [
                kCGImagePropertyOrientation: orientation,
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1],
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1],
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1, kCGImagePropertyGPSLatitudeRef: "N"]
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
