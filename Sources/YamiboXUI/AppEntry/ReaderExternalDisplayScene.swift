import SwiftUI
import UIKit

/// Receives only the dedicated noninteractive scene, never a SwiftUI app
/// window. UIKit can connect it before the shared app services are ready.
public final class ReaderExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    weak var displayCoordinator: ReaderExternalDisplayCoordinator?
    private(set) var registrationID: UUID?
    private(set) var sceneIdentifier: String?
    private(set) weak var scene: UIWindowScene?
    public var window: UIWindow?
    private var controller: ReaderExternalDisplayContainer?
    private var retirement: Task<Void, Never>?

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
        retirement?.cancel()
        if window != nil { removeWindow() }
        let window = UIWindow(windowScene: scene)
        window.backgroundColor = .black
        // The noninteractive scene does not inherit the owner window's appearance.
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
    }

    func retireWindow() {
        conceal(true)
        // Give the connected display a committed neutral frame before UIKit
        // removes the accessory. Immediate removal can leave the compositor's
        // previous buffer presented even though the app window is gone.
        retirement?.cancel()
        guard scene != nil, window != nil else { removeWindow(); return }
        retirement = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            self?.removeWindow()
        }
    }
}

/// The privacy layer is a sibling *above* the hosting view and isn't itself
/// a modal presentation. UIKit doesn't reorder it below a SwiftUI update.
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
            // Keep the viewport mounted for initial layout and restoration.
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

/// Keep one accessory on the owner controller, including while its reader
/// view is being exchanged for a trackpad or a device interaction.
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
        private var deactivation: Task<Void, Never>?
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
            deactivation?.cancel()
            deactivation = nil
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
            deactivation?.cancel()
            deactivation = nil
            let stop = unregister
            unregister = nil
            availability = nil
            sampledAvailability = nil
            setEnabled = nil
            registrationID = nil
            stop?(self)
        }

        func disableAfterPrivacyFrame() {
            guard setEnabled != nil else { return }
            deactivation?.cancel()
            // Disable only after the old window has painted black. A cover
            // that remains mounted can offer the same registration again.
            deactivation = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                self?.setEnabled?(false)
                self?.deactivation = nil
            }
        }
    }
}
