import SwiftUI
import Observation
import YamiboXCore

/// One presentation of a reader. Platform views detach without ending the
/// reader, and a retiring presentation can't remove its successor's handler.
@MainActor
final class ReaderViewportLifetime {
    typealias DeviceMenu = @MainActor (EdgeInsets, _ isVisible: Bool) -> AnyView

    @Observable
    fileprivate final class DeviceMenuRegistration {
        var menu: DeviceMenu?
    }

    let settingsTarget: ReaderSettingsTarget
    private weak var peripheralInput: ReaderPeripheralInputManager?
    private var handlerToken: UUID?
    private var attachmentID: UUID?
    private var capturePosition: (() -> Void)?
    private var onDetach: (() -> Void)?
    private let menuRegistration = DeviceMenuRegistration()
    var deviceMenu: DeviceMenu? { menuRegistration.menu }
    var didRender: (() -> Void)?
    private(set) var isCurrent = true
    private var hasDetached = false
    private var isSuspended = false
    private var isInputPaused = false
    private var inputRevision = 0
    private(set) var hasRendered = false

    init(settingsTarget: ReaderSettingsTarget = .device) {
        self.settingsTarget = settingsTarget
    }

    func attach(
        _ id: UUID,
        peripheralInput: ReaderPeripheralInputManager,
        capturePosition: (() -> Void)? = nil,
        onDetach: (() -> Void)? = nil,
        externalInput: ReaderExternalInput? = nil,
        deviceMenu: DeviceMenu? = nil,
        handleInput: @escaping (ReaderControlEvent) -> Void
    ) {
        guard isCurrent, attachmentID != id else { return }
        capturePosition?()
        detach()
        hasDetached = false
        attachmentID = id
        self.capturePosition = capturePosition
        self.onDetach = onDetach
        self.peripheralInput = peripheralInput
        menuRegistration.menu = deviceMenu
        externalInput?.buttonViewport = self
        handlerToken = peripheralInput.pushHandler { [weak self] event in
            guard self?.acceptsInput(id) == true else { return }
            handleInput(event)
        }
    }

    func performExternalPageStep(_ direction: ReaderControlScrollDirection) -> Bool {
        guard let attachmentID, acceptsInput(attachmentID), let peripheralInput else { return false }
        return peripheralInput.dispatchExternalPageStep(direction)
    }

    func ownsAttachment(_ id: UUID) -> Bool { isCurrent && attachmentID == id }

    func accepts(_ id: UUID) -> Bool { !isSuspended && ownsAttachment(id) }

    func acceptsInput(_ id: UUID) -> Bool { !isInputPaused && accepts(id) }

    /// Queued work must still belong to the same uninterrupted input interval.
    func enqueueInput(_ id: UUID, while admits: @escaping () -> Bool, _ operation: @escaping () async -> Void) {
        guard acceptsInput(id) else { return }
        let revision = inputRevision
        Task { [weak self] in
            guard let self, inputRevision == revision, acceptsInput(id), admits() else { return }
            await operation()
        }
    }

    func frameDidRender() {
        guard isCurrent, !hasDetached else { return }
        hasRendered = true
        if !isSuspended { didRender?() }
    }

    /// UIKit can enqueue geometry before SwiftUI runs the appearance callback,
    /// but geometry from a previously detached presentation is never admitted.
    var acceptsGeometry: Bool { isCurrent && !hasDetached && !isSuspended }

    func synchronizePosition() {
        guard acceptsGeometry else { return }
        capturePosition?()
    }

    func setSuspended(_ suspended: Bool, capturingPosition: Bool = true) {
        guard isSuspended != suspended else { return }
        if suspended && capturingPosition { synchronizePosition() }
        isSuspended = suspended
        inputRevision &+= 1
    }

    func setInputPaused(_ paused: Bool) {
        guard isInputPaused != paused else { return }
        isInputPaused = paused
        inputRevision &+= 1
    }

    @discardableResult
    func detach(_ id: UUID) -> Bool {
        guard attachmentID == id else { return false }
        synchronizePosition()
        hasDetached = true
        detach()
        return true
    }

    func retire(capturingPosition: Bool) {
        guard isCurrent else { return }
        if capturingPosition { synchronizePosition() }
        isCurrent = false
        didRender = nil
        detach()
    }

    private func detach() {
        inputRevision &+= 1
        peripheralInput?.removeHandler(handlerToken)
        handlerToken = nil
        attachmentID = nil
        capturePosition = nil
        menuRegistration.menu = nil
        let cleanup = onDetach
        onDetach = nil
        cleanup?()
    }
}
