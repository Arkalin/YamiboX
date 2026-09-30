import CoreImage
import Foundation
import YamiboXCore

struct BackgroundContrastRequest: Equatable, Sendable {
    let imageData: Data?
    let settings: CustomBackgroundSettings
    let containerSize: CGSize
    let textRect: CGRect
}

/// Downsamples the displayed crop off the main actor, then averages linear sRGB
/// luminance over the actual text bounds. No image-wide brightness heuristic.
actor BackgroundTextContrast {
    static let shared = BackgroundTextContrast()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var cache: [(BackgroundContrastRequest, Bool)] = []

    func usesBlack(for request: BackgroundContrastRequest) -> Bool? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache.first(where: { $0.0 == request }) { return cached.1 }
        guard let data = request.imageData,
              let source = CIImage(data: data, options: [.applyOrientationProperty: true]),
              request.containerSize.width > 0, request.containerSize.height > 0,
              !request.textRect.isEmpty else { return nil }
        let frame = CustomBackgroundLayout.renderedFrame(imageSize: source.extent.size,
                                                         containerSize: request.containerSize, settings: request.settings)
        let sampleScale = min(1, 256 / max(request.containerSize.width, request.containerSize.height))
        let origin = CGPoint(x: (request.containerSize.width - frame.size.width) / 2 + frame.offset.width,
                             y: (request.containerSize.height - frame.size.height) / 2 - frame.offset.height)
        let scaled = source
            .transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: frame.size.width / source.extent.width * sampleScale,
                                              y: frame.size.height / source.extent.height * sampleScale))
            .transformed(by: CGAffineTransform(translationX: origin.x * sampleScale, y: origin.y * sampleScale))
        let blurred = scaled.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: request.settings.blurRadius * sampleScale])
        let rect = CGRect(x: request.textRect.minX * sampleScale,
                          y: (request.containerSize.height - request.textRect.maxY) * sampleScale,
                          width: request.textRect.width * sampleScale, height: request.textRect.height * sampleScale)
        let width = 64, height = 16
        let sample = blurred.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / rect.width, y: CGFloat(height) / rect.height))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        context.render(sample, toBitmap: &pixels, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: colorSpace)
        var luminance = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            luminance += 0.2126 * linear(pixels[index]) + 0.7152 * linear(pixels[index + 1]) + 0.0722 * linear(pixels[index + 2])
        }
        luminance /= Double(width * height)
        let usesBlack = (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05)
        cache.append((request, usesBlack))
        if cache.count > 8 { cache.removeFirst() }
        return usesBlack
    }

    private func linear(_ value: UInt8) -> Double {
        let channel = Double(value) / 255
        return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}
