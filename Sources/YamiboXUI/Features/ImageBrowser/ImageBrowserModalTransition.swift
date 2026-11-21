#if os(iOS)
import SwiftUI
import UIKit

private struct ImageBrowserModalPresenter<Item: Identifiable, Content: View>: UIViewControllerRepresentable {
    @Binding var item: Item?
    let content: (Item) -> Content
    @Environment(\.yamiboImagePipeline) private var imagePipeline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(item: Binding<Item?>, content: @escaping (Item) -> Content) {
        _item = item
        self.content = content
    }

    func makeUIViewController(context: Context) -> Host { Host() }

    func updateUIViewController(_ host: Host, context: Context) {
        host.item = item
        host.makeRoot = { item in AnyView(content(item).environment(\.yamiboImagePipeline, imagePipeline)) }
        host.animates = !reduceMotion
        host.scheduleUpdate()
    }

    static func dismantleUIViewController(_ host: Host, coordinator: Void) { host.stop() }

    final class Host: UIViewController {
        var item: Item?
        var makeRoot: ((Item) -> AnyView)?
        var animates = true

        private var presentedBrowser: UIHostingController<AnyView>?
        private var presentedID: Item.ID?
        private var transitionInProgress = false
        private var updateScheduled = false
        private var stopped = false

        override func loadView() {
            view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            scheduleUpdate()
        }

        func scheduleUpdate() {
            guard !stopped, !updateScheduled else { return }
            updateScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                updateScheduled = false
                reconcilePresentation()
            }
        }

        func stop() {
            stopped = true
            item = nil
            makeRoot = nil
            if !transitionInProgress { removeBrowser(animated: false) }
        }

        private func reconcilePresentation() {
            guard !transitionInProgress else { return }
            if stopped {
                removeBrowser(animated: false)
                return
            }
            if let current = presentedBrowser {
                if let item, presentedID == item.id, let makeRoot {
                    current.rootView = makeRoot(item)
                } else {
                    removeBrowser(animated: animates)
                }
                return
            }
            guard let item, let makeRoot, viewIfLoaded?.window != nil, presentedViewController == nil else { return }
            let browser = UIHostingController(rootView: makeRoot(item))
            browser.modalPresentationStyle = .fullScreen
            browser.modalTransitionStyle = .crossDissolve
            browser.view.backgroundColor = .black
            browser.isModalInPresentation = true
            presentedBrowser = browser
            presentedID = item.id
            transitionInProgress = true
            present(browser, animated: animates) { [weak self] in
                guard let self else { return }
                transitionInProgress = false
                if stopped { removeBrowser(animated: false) }
                else { scheduleUpdate() }
            }
        }

        private func removeBrowser(animated: Bool) {
            guard let browser = presentedBrowser else { return }
            transitionInProgress = true
            browser.dismiss(animated: animated) { [weak self] in
                guard let self else { return }
                presentedBrowser = nil
                presentedID = nil
                transitionInProgress = false
                scheduleUpdate()
            }
        }
    }
}

private struct ImageBrowserModalFlag: Identifiable {
    let id = true
}

extension View {
    func imageBrowserCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        background(ImageBrowserModalPresenter(item: item, content: content).frame(width: 0, height: 0))
    }

    func imageBrowserCover<Content: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let item = Binding<ImageBrowserModalFlag?>(
            get: { isPresented.wrappedValue ? ImageBrowserModalFlag() : nil },
            set: { isPresented.wrappedValue = $0 != nil }
        )
        return imageBrowserCover(item: item) { _ in content() }
    }
}
#endif
