import Foundation

public struct CustomBackgroundSettings: Codable, Hashable, Sendable {
    public static let minimumScale = 1.0
    public static let maximumScale = 3.0
    public static let minimumOffset = -1.0
    public static let maximumOffset = 1.0
    public static let minimumBlurRadius = 0.0
    public static let maximumBlurRadius = 30.0

    public var isEnabled: Bool
    public var imageID: String?
    public var scale: Double
    public var offsetX: Double
    public var offsetY: Double
    public var blurRadius: Double

    public init(
        isEnabled: Bool = false,
        imageID: String? = nil,
        scale: Double = 1.0,
        offsetX: Double = 0,
        offsetY: Double = 0,
        blurRadius: Double = 0
    ) {
        self.isEnabled = isEnabled
        self.imageID = imageID
        self.scale = Self.clampScale(scale)
        self.offsetX = Self.clampOffset(offsetX)
        self.offsetY = Self.clampOffset(offsetY)
        self.blurRadius = Self.clampBlurRadius(blurRadius)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decode(Bool.self, forKey: .isEnabled),
            imageID: try container.decodeIfPresent(String.self, forKey: .imageID),
            scale: try container.decode(Double.self, forKey: .scale),
            offsetX: try container.decode(Double.self, forKey: .offsetX),
            offsetY: try container.decode(Double.self, forKey: .offsetY),
            blurRadius: try container.decode(Double.self, forKey: .blurRadius)
        )
    }

    public static func clampScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(maximumScale, max(minimumScale, value))
    }

    public static func clampOffset(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(maximumOffset, max(minimumOffset, value))
    }

    public static func clampBlurRadius(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(maximumBlurRadius, max(minimumBlurRadius, value))
    }
}
