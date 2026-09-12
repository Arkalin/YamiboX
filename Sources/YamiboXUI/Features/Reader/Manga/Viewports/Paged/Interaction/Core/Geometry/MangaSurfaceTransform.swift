import Foundation

/// Read-only presentation snapshot reported by the native zoom host.
struct MangaSurfaceTransform: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
}

enum MangaContinuousInput: Hashable { case pan, pinch }
