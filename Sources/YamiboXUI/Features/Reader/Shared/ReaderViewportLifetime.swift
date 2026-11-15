import SwiftUI
import YamiboXCore

/// One presentation of a reader. Platform views detach without ending the
/// reader, and a retiring presentation can't remove its successor's handler.
@MainActor
final class ReaderViewportLifetime {
    typealias DeviceMenu = @MainActor (EdgeInsets) -> AnyView

    let settingsTarget: ReaderSettingsTarget
    private weak var peripheralInput: ReaderPeripheralInputManager?
    private var handlerToken: UUID?
    private var attachmentID: UUID?
    private var capturePosition: (() -> Void)?
    private var onDetach: (() -> Void)?
    private(set) var deviceMenu: DeviceMenu?
    var didRender: (() -> Void)?
    private(set) var isCurrent = true
    private var hasDetached = false
    private var isSuspended = false
    private var isInputPaused = false
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
        self.deviceMenu = deviceMenu
        externalInput?.buttonViewport = self
        handlerToken = peripheralInput.pushHandler { [weak self] event in
            guard self?.acceptsInput(id) == true else { return }
            handleInput(event)
        }
    }

    func performExternalPageStep(_ direction: ReaderControlScrollDirection) {
        guard let attachmentID, acceptsInput(attachmentID) else { return }
        peripheralInput?.dispatchExternalPageStep(direction)
    }

    func accepts(_ id: UUID) -> Bool {
        isCurrent && !isSuspended && attachmentID == id
    }

    func acceptsInput(_ id: UUID) -> Bool { !isInputPaused && accepts(id) }

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
        if suspended && capturingPosition { synchronizePosition() }
        isSuspended = suspended
    }

    func setInputPaused(_ paused: Bool) { isInputPaused = paused }

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
        peripheralInput?.removeHandler(handlerToken)
        handlerToken = nil
        attachmentID = nil
        capturePosition = nil
        deviceMenu = nil
        let cleanup = onDetach
        onDetach = nil
        cleanup?()
    }
}
