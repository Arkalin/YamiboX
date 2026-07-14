import SwiftUI

struct ReaderCacheDownloadQueueIcon: View {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimated)) { context in
            let progress = isAnimated ? animationProgress(at: context.date) : 0
            ZStack {
                trayPath
                    .stroke(style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))

                arrowPath(yOffset: arrowYOffset(progress: progress))
                    .stroke(style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))
                    .opacity(arrowOpacity(progress: progress))
            }
            .frame(width: 24, height: 24)
        }
    }

    private var trayPath: Path {
        Path { path in
            path.move(to: CGPoint(x: 8.2, y: 8.6))
            path.addLine(to: CGPoint(x: 4.9, y: 8.6))
            path.addLine(to: CGPoint(x: 4.9, y: 17.8))
            path.addCurve(
                to: CGPoint(x: 7.2, y: 20.1),
                control1: CGPoint(x: 4.9, y: 19.1),
                control2: CGPoint(x: 5.9, y: 20.1)
            )
            path.addLine(to: CGPoint(x: 16.8, y: 20.1))
            path.addCurve(
                to: CGPoint(x: 19.1, y: 17.8),
                control1: CGPoint(x: 18.1, y: 20.1),
                control2: CGPoint(x: 19.1, y: 19.1)
            )
            path.addLine(to: CGPoint(x: 19.1, y: 8.6))
            path.addLine(to: CGPoint(x: 15.8, y: 8.6))
        }
    }

    private func arrowPath(yOffset: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 12.0, y: 3.2 + yOffset))
            path.addLine(to: CGPoint(x: 12.0, y: 14.8 + yOffset))
            path.move(to: CGPoint(x: 7.9, y: 11.1 + yOffset))
            path.addLine(to: CGPoint(x: 12.0, y: 15.2 + yOffset))
            path.addLine(to: CGPoint(x: 16.1, y: 11.1 + yOffset))
        }
    }

    private var isAnimated: Bool {
        isActive && !accessibilityReduceMotion
    }

    private func animationProgress(at date: Date) -> Double {
        let duration = 1.05
        return date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: duration) / duration
    }

    private func arrowYOffset(progress: Double) -> CGFloat {
        guard isAnimated else { return 0 }
        return -6 + CGFloat(progress) * 10
    }

    private func arrowOpacity(progress: Double) -> Double {
        guard isAnimated else { return 1 }
        if progress < 0.76 {
            return 1
        }
        return max(0, 1 - ((progress - 0.76) / 0.24))
    }
}
