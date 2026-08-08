import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
final class NovelReaderSearchHighlightController {
    struct ResolvedHighlight {
        let rects: [CGRect]
        let opacity: CGFloat
    }

    private let registeredViews = NSHashTable<NovelTextViewportReferenceUIView>.weakObjects()
    private var start: NovelResumePoint?
    private var end: NovelResumePoint?
    private var opacity: CGFloat = 1
    private var clearTask: Task<Void, Never>?

    deinit {
        clearTask?.cancel()
    }

    func register(_ view: NovelTextViewportReferenceUIView) {
        registeredViews.add(view)
        view.setNeedsDisplay()
    }

    func unregister(_ view: NovelTextViewportReferenceUIView) {
        registeredViews.remove(view)
    }

    func highlight(from start: NovelResumePoint, to end: NovelResumePoint) {
        clearTask?.cancel()
        self.start = start
        self.end = end
        opacity = 1
        redrawRegisteredViews()

        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.75))
            guard !Task.isCancelled, let self else { return }
            for step in 1...10 {
                self.opacity = 1 - CGFloat(step) / 10
                self.redrawRegisteredViews()
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled else { return }
            }
            self.clear()
        }
    }

    func clear() {
        clearTask?.cancel()
        clearTask = nil
        start = nil
        end = nil
        opacity = 1
        redrawRegisteredViews()
    }

    func resolvedHighlight(
        for displayReference: NovelTextViewportDisplayReference
    ) -> ResolvedHighlight? {
        guard let start, let end,
              let range = displayReference.highlightRange(from: start, to: end) else {
            return nil
        }
        let rects = displayReference.selectionRects(for: range)
        guard !rects.isEmpty else { return nil }
        return ResolvedHighlight(rects: rects, opacity: opacity)
    }

    private func redrawRegisteredViews() {
        for view in registeredViews.allObjects {
            view.setNeedsDisplay()
        }
    }
}
#endif
