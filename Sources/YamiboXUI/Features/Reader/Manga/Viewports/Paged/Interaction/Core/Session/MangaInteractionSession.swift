import Foundation

struct MangaSurfaceTransform: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
}

enum MangaContinuousInput: Hashable { case pan, pinch }

/// One snapshot for all joined recognizers. Ended members retain their increments
/// until the last member ends; cancellation rolls back even an already-ended pan.
struct MangaInteractionSession {
    let generation: UInt64
    let snapshot: MangaSurfaceTransform
    private(set) var members: Set<MangaContinuousInput> = []
    private(set) var joined: Set<MangaContinuousInput> = []
    private var translation: CGSize = .zero
    private var magnification: CGFloat = 1

    init(generation: UInt64, snapshot: MangaSurfaceTransform) {
        self.generation = generation
        self.snapshot = snapshot
    }

    mutating func begin(_ input: MangaContinuousInput) -> Bool {
        guard !joined.contains(input) else { return false }
        joined.insert(input)
        members.insert(input)
        return true
    }

    mutating func pan(_ translation: CGSize) {
        guard members.contains(.pan) else { return }
        self.translation = translation
    }

    mutating func pinch(_ magnification: CGFloat) {
        guard members.contains(.pinch), magnification.isFinite, magnification > 0 else { return }
        self.magnification = magnification
    }

    mutating func end(_ input: MangaContinuousInput) {
        members.remove(input)
    }

    var proposed: MangaSurfaceTransform {
        let scale = MangaPageZoomPolicy.clampedScale(snapshot.scale * magnification)
        return MangaSurfaceTransform(
            scale: scale,
            offset: CGSize(
                width: snapshot.offset.width + translation.width,
                height: snapshot.offset.height + (MangaPageZoomPolicy.isActive(scale) ? translation.height : 0)
            )
        )
    }
}
