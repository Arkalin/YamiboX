import SceneKit
import SwiftUI

/// A solid, rounded icon with independently lit edges, not a rotated flat image.
struct AboutInteractiveIcon: UIViewRepresentable {
    let image: UIImage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    func makeUIView(context: Context) -> IconSceneView {
        IconSceneView(image: image)
    }

    func updateUIView(_ view: IconSceneView, context: Context) {
        view.reduceMotion = reduceMotion
        if scenePhase != .active || reduceMotion {
            view.reset(animated: false)
        }
        view.isPlaying = scenePhase == .active
    }

    static func dismantleUIView(_ view: IconSceneView, coordinator: ()) {
        view.reset(animated: false)
        view.isPlaying = false
        view.scene = nil
    }
}

final class IconSceneView: SCNView, UIGestureRecognizerDelegate {
    private static let spinActionKey = "about-icon-spin"
    var reduceMotion = false
    private let icon = SCNNode()
    private let tapFeedback = UIImpactFeedbackGenerator(style: .light)
    private var dragOrigin = SCNVector3Zero
    private let restingAngles = SCNVector3Zero

    init(image: UIImage) {
        super.init(frame: .zero, options: nil)
        backgroundColor = .clear
        isOpaque = false
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 60
        // Render on demand when idle; no perpetual decorative animation.
        rendersContinuously = false
        autoenablesDefaultLighting = false

        let scene = SCNScene()
        self.scene = scene
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 36
        camera.position = SCNVector3(0, 0, 5.3)
        scene.rootNode.addChildNode(camera)
        pointOfView = camera

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 750
        scene.rootNode.addChildNode(ambient)
        for (position, intensity) in [(SCNVector3(-3, 4, 5), 950.0), (SCNVector3(4, -1, 2), 450.0)] {
            let light = SCNNode()
            light.light = SCNLight()
            light.light?.type = .omni
            light.light?.intensity = intensity
            light.position = position
            scene.rootNode.addChildNode(light)
        }

        let outline = UIBezierPath(roundedRect: CGRect(x: -1, y: -1, width: 2, height: 2), cornerRadius: 0.44)
        outline.flatness = 0.005
        let body = SCNShape(path: outline, extrusionDepth: 0.22)
        body.chamferRadius = 0.035
        let edge = SCNMaterial()
        // Match the solid fill in AppIcon.icon/icon.json on the sides and back.
        edge.diffuse.contents = UIColor(red: 0.32157, green: 0.10980, blue: 0.03922, alpha: 1)
        edge.specular.contents = UIColor(white: 0.3, alpha: 1)
        edge.shininess = 0.65
        body.materials = [edge]
        icon.addChildNode(SCNNode(geometry: body))

        // Artwork is only on the front; the solid body supplies the plain back.
        let face = SCNPlane(width: 1.99, height: 1.99)
        face.cornerRadius = 0.44
        face.cornerSegmentCount = 24
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.lightingModel = .blinn
        material.specular.contents = UIColor(white: 0.3, alpha: 1)
        material.shininess = 0.65
        face.materials = [material]
        let front = SCNNode(geometry: face)
        front.position.z = 0.112
        icon.addChildNode(front)
        icon.eulerAngles = restingAngles
        scene.rootNode.addChildNode(icon)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(spin))
        tap.require(toFail: pan)
        addGestureRecognizer(tap)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "about-interactive-icon"
        accessibilityLabel = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Yamibo X"
    }

    required init?(coder: NSCoder) { nil }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        // Vertical-first drags remain available to the surrounding ScrollView.
        return abs(velocity.x) > abs(velocity.y)
    }

    @objc private func drag(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            let visibleAngles = icon.presentation.eulerAngles
            icon.removeAllActions()
            icon.eulerAngles = visibleAngles
            dragOrigin = visibleAngles
        case .changed:
            let translation = pan.translation(in: self)
            icon.eulerAngles = SCNVector3(
                max(-0.9, min(0.9, dragOrigin.x + Float(translation.y / 140))),
                dragOrigin.y + Float(translation.x / 75),
                0
            )
        case .ended, .cancelled, .failed:
            reset(animated: !reduceMotion)
        default:
            break
        }
    }

    func reset(animated: Bool) {
        let visibleAngles = icon.presentation.eulerAngles
        icon.removeAllActions()
        icon.eulerAngles = visibleAngles
        guard animated else {
            icon.eulerAngles = restingAngles
            return
        }
        let settle = SCNAction.rotateTo(
            x: CGFloat(restingAngles.x), y: CGFloat(restingAngles.y), z: 0,
            duration: 0.75, usesShortestUnitArc: true
        )
        settle.timingFunction = { t in
            // A small overshoot gives the icon a soft spring-like return.
            let p = t - 1
            return 1 + 2.4 * p * p * p + 1.4 * p * p
        }
        icon.runAction(settle)
    }

    @objc private func spin() {
        tapFeedback.impactOccurred(intensity: 0.5)
        if icon.action(forKey: Self.spinActionKey) != nil {
            // A second tap during the flip means settle back to the front,
            // not restart the turn or leave the model at an arbitrary angle.
            reset(animated: !reduceMotion)
            return
        }

        // Preserve the current pose if a new turn begins during a settle animation.
        let visibleAngles = icon.presentation.eulerAngles
        icon.removeAllActions()
        icon.eulerAngles = visibleAngles
        guard !reduceMotion else {
            icon.eulerAngles = restingAngles
            return
        }
        let turn = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 1.1)
        turn.timingMode = .easeInEaseOut
        icon.runAction(turn, forKey: Self.spinActionKey)
    }

    override func accessibilityActivate() -> Bool {
        spin()
        return true
    }
}
