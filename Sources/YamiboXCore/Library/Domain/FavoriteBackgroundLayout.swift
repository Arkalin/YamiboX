import CoreGraphics
import Foundation

public struct FavoriteBackgroundRenderedFrame: Equatable, Sendable {
    public var size: CGSize
    public var offset: CGSize

    public init(size: CGSize, offset: CGSize) {
        self.size = size
        self.offset = offset
    }
}

public enum FavoriteBackgroundLayout {
    public static func renderedFrame(
        imageSize: CGSize,
        containerSize: CGSize,
        settings: FavoriteBackgroundSettings
    ) -> FavoriteBackgroundRenderedFrame {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return FavoriteBackgroundRenderedFrame(size: .zero, offset: .zero)
        }

        let fillScale = max(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let relativeScale = FavoriteBackgroundSettings.clampScale(settings.scale)
        let renderedSize = CGSize(
            width: imageSize.width * fillScale * relativeScale,
            height: imageSize.height * fillScale * relativeScale
        )
        let overflowX = max(0, (renderedSize.width - containerSize.width) / 2)
        let overflowY = max(0, (renderedSize.height - containerSize.height) / 2)
        let offset = CGSize(
            width: overflowX * FavoriteBackgroundSettings.clampOffset(settings.offsetX),
            height: overflowY * FavoriteBackgroundSettings.clampOffset(settings.offsetY)
        )

        return FavoriteBackgroundRenderedFrame(size: renderedSize, offset: offset)
    }

    public static func normalizedOffsets(
        imageSize: CGSize,
        containerSize: CGSize,
        scale: Double,
        proposedOffset: CGSize
    ) -> (offsetX: Double, offsetY: Double) {
        let settings = FavoriteBackgroundSettings(scale: scale)
        let frame = renderedFrame(imageSize: imageSize, containerSize: containerSize, settings: settings)
        let overflowX = max(0, (frame.size.width - containerSize.width) / 2)
        let overflowY = max(0, (frame.size.height - containerSize.height) / 2)

        return (
            offsetX: overflowX > 0 ? FavoriteBackgroundSettings.clampOffset(proposedOffset.width / overflowX) : 0,
            offsetY: overflowY > 0 ? FavoriteBackgroundSettings.clampOffset(proposedOffset.height / overflowY) : 0
        )
    }
}
