import Foundation

struct ReadingHomeHeaderMotion {
    let scrollOffset: CGFloat

    var titleOpacity: Double {
        1 - progress(from: 8, to: 48)
    }

    var avatarOpacity: Double {
        1 - progress(from: 32, to: 88)
    }

    var avatarBlurRadius: CGFloat {
        10 * progress(from: 32, to: 88)
    }

    private func progress(from start: CGFloat, to end: CGFloat) -> Double {
        let fraction = Double(min(1, max(0, (scrollOffset - start) / (end - start))))
        return fraction * fraction * (3 - 2 * fraction)
    }
}
