import CoreGraphics
import Foundation

public struct CustomBackgroundRenderedFrame: Equatable, Sendable {
    public var size: CGSize
    public var offset: CGSize

    public init(size: CGSize, offset: CGSize) {
        self.size = size
        self.offset = offset
    }
}

public enum CustomBackgroundLayout {
    public static func renderedFrame(
        imageSize: CGSize,
        containerSize: CGSize,
        settings: CustomBackgroundSettings
    ) -> CustomBackgroundRenderedFrame {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return CustomBackgroundRenderedFrame(size: .zero, offset: .zero)
        }

        let fillScale = max(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let relativeScale = CustomBackgroundSettings.clampScale(settings.scale)
        let renderedSize = CGSize(
            width: imageSize.width * fillScale * relativeScale,
            height: imageSize.height * fillScale * relativeScale
        )
        let overflowX = max(0, (renderedSize.width - containerSize.width) / 2)
        let overflowY = max(0, (renderedSize.height - containerSize.height) / 2)
        let offset = CGSize(
            width: overflowX * CustomBackgroundSettings.clampOffset(settings.offsetX),
            height: overflowY * CustomBackgroundSettings.clampOffset(settings.offsetY)
        )

        return CustomBackgroundRenderedFrame(size: renderedSize, offset: offset)
    }

    public static func normalizedOffsets(
        imageSize: CGSize,
        containerSize: CGSize,
        scale: Double,
        proposedOffset: CGSize
    ) -> (offsetX: Double, offsetY: Double) {
        let settings = CustomBackgroundSettings(scale: scale)
        let frame = renderedFrame(imageSize: imageSize, containerSize: containerSize, settings: settings)
        let overflowX = max(0, (frame.size.width - containerSize.width) / 2)
        let overflowY = max(0, (frame.size.height - containerSize.height) / 2)

        return (
            offsetX: overflowX > 0 ? CustomBackgroundSettings.clampOffset(proposedOffset.width / overflowX) : 0,
            offsetY: overflowY > 0 ? CustomBackgroundSettings.clampOffset(proposedOffset.height / overflowY) : 0
        )
    }
}
