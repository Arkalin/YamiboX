import SwiftUI
import UIKit

public final class ReaderExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    weak var displayCoordinator: ReaderExternalDisplayCoordinator?
    private(set) var registrationID: UUID?
    private(set) var sceneIdentifier: String?
    private(set) weak var scene: UIWindowScene?
    public var window: UIWindow?
    private var controller: ReaderExternalDisplayContainer?
    private var privacyFrame: ReaderExternalDisplayPrivacyFrame?

    public func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard session.role == .windowExternalDisplayNonInteractive, let scene = scene as? UIWindowScene else { return }
        if #available(iOS 27, *) {
            guard let id = options.sceneAccessoryUserInfo as? String, let parsed = UUID(uuidString: id) else { return }
            registrationID = parsed
        }
        sceneIdentifier = session.persistentIdentifier
        self.scene = scene
        ReaderExternalDisplayScenes.shared.connect(self)
    }

    public func sceneDidDisconnect(_ scene: UIScene) {
        self.scene = nil
        ReaderExternalDisplayScenes.shared.disconnect(self)
        removeWindow()
    }

    func show<Content: View>(_ content: Content, interfaceStyle: UIUserInterfaceStyle) -> Bool {
        guard let scene else { return false }
        if window != nil { removeWindow() }
        let window = UIWindow(windowScene: scene)
        window.backgroundColor = .black
        window.overrideUserInterfaceStyle = interfaceStyle
        let controller = ReaderExternalDisplayContainer(host: UIHostingController(rootView: content))
        window.rootViewController = controller
        self.controller = controller
        self.window = window
        window.isHidden = false
        return true
    }

    func conceal(_ concealed: Bool) {
        controller?.conceal(concealed)
    }

    func removeWindow() {
        conceal(true)
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        controller = nil
        let pendingFrame = privacyFrame
        privacyFrame = nil
        pendingFrame?.finish()
    }

    func afterPrivacyFrame(_ action: @escaping () -> Void) {
        conceal(true)
        guard let scene, window != nil else {
            action()
            return
        }
        if let privacyFrame {
            privacyFrame.append(action)
            return
        }
        let frame = ReaderExternalDisplayPrivacyFrame()
        privacyFrame = frame
        frame.append { [weak self, weak frame] in
            guard let self, privacyFrame === frame else { return }
            privacyFrame = nil
        }
        frame.append(action)
        frame.start(in: scene)
    }

    func retireWindow() {
        guard let retiredWindow = window else { return }
        afterPrivacyFrame { [weak self, weak retiredWindow] in
            guard let self, let retiredWindow, window === retiredWindow else { return }
            removeWindow()
        }
    }
}

@MainActor
private final class ReaderExternalDisplayPrivacyFrame: NSObject {
    private var link: CADisplayLink?
    private var fallback: Task<Void, Never>?
    private var callbacks: [() -> Void] = []
    private var frameTicks = 0
    private let ticksToSubmitNeutralFrame = 2
    private let pausedDisplayFallback: Duration = .milliseconds(250)

    func append(_ callback: @escaping () -> Void) { callbacks.append(callback) }

    func start(in scene: UIWindowScene) {
        let selector = #selector(frameWillRefresh(_:))
        if #available(iOS 27, *) {
            link = scene.displayLink(target: self, selector: selector)
        } else {
            link = scene.screen.displayLink(withTarget: self, selector: selector)
        }
        link?.add(to: .main, forMode: .common)
        fallback = Task { @MainActor [weak self] in
            guard let deadline = self?.pausedDisplayFallback else { return }
            do { try await Task.sleep(for: deadline) } catch { return }
            self?.finish()
        }
    }

    @objc private func frameWillRefresh(_ link: CADisplayLink) {
        frameTicks += 1
        if frameTicks >= ticksToSubmitNeutralFrame { finish() }
    }

    func finish() {
        link?.invalidate()
        link = nil
        fallback?.cancel()
        fallback = nil
        let actions = callbacks
        callbacks.removeAll()
        for action in actions { action() }
    }
}

private final class ReaderExternalDisplayContainer: UIViewController {
    let host: UIViewController
    let cover = UIView()

    init(host: UIViewController) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        cover.frame = view.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = .black
        cover.accessibilityElementsHidden = true
        view.addSubview(cover)
        conceal(true)
    }

    func conceal(_ concealed: Bool) {
        loadViewIfNeeded()
        UIView.performWithoutAnimation {
            host.view.accessibilityElementsHidden = concealed
            cover.isHidden = !concealed
            view.bringSubviewToFront(cover)
        }
    }
}

@MainActor
final class ReaderExternalDisplayScenes {
    static let shared = ReaderExternalDisplayScenes()
    private let connections = NSHashTable<ReaderExternalDisplaySceneDelegate>.weakObjects()
    weak var coordinator: ReaderExternalDisplayCoordinator?
    var available: [ReaderExternalDisplaySceneDelegate] { connections.allObjects }

    func connect(_ connection: ReaderExternalDisplaySceneDelegate) {
        connections.add(connection)
        coordinator?.displayConnected()
    }

    func disconnect(_ connection: ReaderExternalDisplaySceneDelegate) {
        connections.remove(connection)
        connection.displayCoordinator?.displayDisconnected(connection)
    }
}

struct ReaderExternalDisplayRegistrationHost: UIViewControllerRepresentable {
    let update: (Host) -> Void

    func makeUIViewController(context: Context) -> Host {
        let host = Host()
        host.update = update
        return host
    }

    func updateUIViewController(_ host: Host, context: Context) {
        host.update = update
    }

    static func dismantleUIViewController(_ host: Host, coordinator: Void) {
        host.stop()
        host.update = nil
    }

    final class Host: UIViewController {
        var update: ((Host) -> Void)?
        private(set) var registrationID: UUID?
        private var unregister: ((Host) -> Void)?
        private var availability: (() -> Bool)?
        private var setEnabled: ((Bool) -> Void)?
        private var deactivationID: UUID?
        private var updateTask: Task<Void, Never>?
        private(set) var sampledAvailability: Bool?

        var isAccessoryAvailable: Bool { availability?() ?? false }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            scheduleUpdate()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            scheduleUpdate()
        }

        @available(iOS 26.0, *)
        override func updateProperties() {
            super.updateProperties()
            if availability != nil {
                // UIKit tracks availability reads during this lifecycle event.
                let available = isAccessoryAvailable
                if sampledAvailability != available {
                    sampledAvailability = available
                    scheduleUpdate()
                }
            }
        }

        private func scheduleUpdate() {
            guard updateTask == nil else { return }
            updateTask = Task { @MainActor [weak self] in
                guard let self else { return }
                updateTask = nil
                guard viewIfLoaded?.window != nil else { return }
                update?(self)
            }
        }

        func start(id: UUID) {
            guard #available(iOS 27, *) else { return }
            deactivationID = nil
            if registrationID == id {
                setEnabled?(true)
                return
            }
            stop()
            let configuration = UISceneConfiguration()
            configuration.delegateClass = ReaderExternalDisplaySceneDelegate.self
            let registration = registerSceneAccessory(.externalNonInteractive(
                sceneConfiguration: configuration, userInfo: id.uuidString
            ))
            registrationID = id
            availability = { registration.isAvailable }
            setEnabled = { registration.isEnabled = $0 }
            unregister = { host in host.unregisterSceneAccessory(registration) }
            setNeedsUpdateProperties()
        }

        func stop() {
            deactivationID = nil
            let stop = unregister
            unregister = nil
            availability = nil
            sampledAvailability = nil
            setEnabled = nil
            registrationID = nil
            stop?(self)
        }

        func disableAfterPrivacyFrame(in connection: ReaderExternalDisplaySceneDelegate?) {
            guard setEnabled != nil else { return }
            let requestID = UUID()
            deactivationID = requestID
            let disable = { [weak self] in
                guard let self, deactivationID == requestID else { return }
                deactivationID = nil
                setEnabled?(false)
            }
            if let connection { connection.afterPrivacyFrame(disable) }
            else { disable() }
        }
    }
}
