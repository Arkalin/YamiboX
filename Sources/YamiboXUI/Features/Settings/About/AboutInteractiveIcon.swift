import SceneKit
import SwiftUI

/// An extruded icon with independently lit flower geometry and a solid back.
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
    private let tapFeedback = UIImpactFeedbackGenerator(style: .medium)
    private var dragOrigin = SCNVector3Zero
    private let restingAngles = SCNVector3Zero
    private let bodyMaterial = SCNMaterial()
    private enum Edge { case left, right, top, bottom }
    private var primedEdge: Edge?
    private var verticalDrag = false

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
        // Keep the original front-facing silhouette identical across elevations,
        // and leave enough margin for tilted corners during a drag.
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 1.45
        camera.position = SCNVector3(0, 0, 5.3)
        scene.rootNode.addChildNode(camera)
        pointOfView = camera

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)
        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .directional
        keyLight.light?.intensity = 950
        keyLight.light?.castsShadow = true
        keyLight.light?.shadowMapSize = CGSize(width: 1024, height: 1024)
        keyLight.light?.shadowSampleCount = 8
        keyLight.light?.shadowColor = UIColor.black.withAlphaComponent(0.35)
        keyLight.light?.orthographicScale = 3
        keyLight.position = SCNVector3(-3, 4, 5)
        keyLight.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(keyLight)
        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .omni
        fillLight.light?.intensity = 250
        fillLight.position = SCNVector3(4, -1, 2)
        scene.rootNode.addChildNode(fillLight)
        let rimLight = SCNNode()
        rimLight.light = SCNLight()
        rimLight.light?.type = .omni
        rimLight.light?.intensity = 260
        rimLight.position = SCNVector3(3, 2, -3)
        scene.rootNode.addChildNode(rimLight)

        let outline = UIBezierPath(roundedRect: CGRect(x: -1, y: -1, width: 2, height: 2), cornerRadius: 0.44)
        outline.flatness = 0.005
        let body = SCNShape(path: outline, extrusionDepth: 0.22)
        body.chamferRadius = 0.035
        configureFinish(bodyMaterial, shininess: 0.85, specular: 0.18)
        bodyMaterial.diffuse.contents = UIColor(red: 0.32157, green: 0.10980, blue: 0.03922, alpha: 1)
        body.materials = [bodyMaterial]
        let base = SCNNode(geometry: body)
        base.name = "icon-body"
        icon.addChildNode(base)

        if let artwork = AboutIconGeometry.bundled {
            addFlower(artwork)
        } else {
            // Keep a usable icon if the generated resource is missing or invalid.
            let face = SCNPlane(width: 1.99, height: 1.99)
            face.cornerRadius = 0.44
            face.cornerSegmentCount = 24
            let material = SCNMaterial()
            material.lightingModel = .blinn
            material.diffuse.contents = image
            face.materials = [material]
            let front = SCNNode(geometry: face)
            front.position.z = 0.112
            icon.addChildNode(front)
        }
        icon.eulerAngles = restingAngles
        scene.rootNode.addChildNode(icon)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapEdge(_:)))
        tap.require(toFail: pan)
        addGestureRecognizer(tap)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "about-interactive-icon"
        accessibilityLabel = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Yamibo X"
    }

    required init?(coder: NSCoder) { nil }

    private static let studioLighting: UIImage = {
        let size = CGSize(width: 1024, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            UIColor(white: 0.12, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let colors = [UIColor(white: 0.65, alpha: 1).cgColor, UIColor(white: 0.65, alpha: 0).cgColor]
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) else { return }
            // Broad softboxes, not a painted highlight on the flower itself.
            for center in [CGPoint(x: 230, y: 170), CGPoint(x: 790, y: 210)] {
                context.saveGState()
                context.translateBy(x: center.x, y: center.y)
                context.scaleBy(x: 1, y: 0.65)
                context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 30, endCenter: .zero, endRadius: 190, options: [])
                context.restoreGState()
            }
        }
    }()

    private func configureFinish(_ material: SCNMaterial, shininess: CGFloat, specular: CGFloat) {
        // Bound reflection separately from diffuse lighting so a passing highlight
        // never washes the brown plate into the cream flower.
        material.lightingModel = .blinn
        material.specular.contents = UIColor(white: specular, alpha: 1)
        material.shininess = shininess
        material.reflective.contents = Self.studioLighting
        material.reflective.intensity = 0.04
        material.fresnelExponent = 1.5
    }

    private func addFlower(_ artwork: AboutIconGeometry) {
        let face = SCNMaterial()
        configureFinish(face, shininess: 0.8, specular: 0.24)
        face.diffuse.contents = UIColor(red: 244 / 255, green: 237 / 255, blue: 228 / 255, alpha: 1)
        let side = SCNMaterial()
        configureFinish(side, shininess: 0.65, specular: 0.16)
        side.diffuse.contents = UIColor(red: 214 / 255, green: 195 / 255, blue: 172 / 255, alpha: 1)
        for layer in artwork.layers {
            let shape = SCNShape(path: layer.makePath(canvasSize: artwork.canvasSize), extrusionDepth: layer.extrusionDepth)
            // No bevel erosion: even the original subpixel holes are retained.
            shape.materials = [face, face, side]
            let node = SCNNode(geometry: shape)
            node.name = layer.name
            // All relief starts at the base's front face, rather than floating
            // above it. Different extrusion heights separate petals and stamens.
            node.position.z = Float(0.11 + layer.extrusionDepth / 2)
            icon.addChildNode(node)
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        let translation = pan.translation(in: self)
        let location = pan.location(in: self)
        let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
        guard let point = artworkPoint(at: start) else { return false }
        verticalDrag = abs(velocity.y) > abs(velocity.x)
        // Only the top/bottom edges claim vertical gestures; the center still scrolls.
        return !verticalDrag || edge(at: point) == .top || edge(at: point) == .bottom
    }

    private func artworkPoint(at location: CGPoint) -> SCNVector3? {
        guard let hit = hitTest(location, options: [.rootNode: icon]).first else { return nil }
        return icon.presentation.convertPosition(hit.worldCoordinates, from: nil)
    }

    private func edge(at point: SCNVector3) -> Edge? {
        guard max(abs(point.x), abs(point.y)) >= 0.55 else { return nil }
        if abs(point.x) >= abs(point.y) { return point.x < 0 ? .left : .right }
        return point.y > 0 ? .top : .bottom
    }

    @objc private func drag(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            primedEdge = nil
            let visibleAngles = icon.presentation.eulerAngles
            icon.removeAllActions()
            icon.eulerAngles = visibleAngles
            dragOrigin = visibleAngles
        case .changed:
            let translation = pan.translation(in: self)
            icon.eulerAngles = SCNVector3(
                dragOrigin.x + Float(translation.y / (verticalDrag ? 75 : 140)),
                dragOrigin.y + Float(translation.x / (verticalDrag ? 140 : 75)),
                0
            )
        case .ended, .cancelled, .failed:
            reset(animated: !reduceMotion)
        default:
            break
        }
    }

    func reset(animated: Bool) {
        primedEdge = nil
        let visibleAngles = icon.presentation.eulerAngles
        icon.removeAllActions()
        icon.eulerAngles = visibleAngles
        guard animated else {
            icon.eulerAngles = restingAngles
            return
        }
        icon.runAction(settleAction())
    }

    private func settleAction() -> SCNAction {
        let settle = SCNAction.rotateTo(
            x: CGFloat(restingAngles.x), y: CGFloat(restingAngles.y), z: 0,
            duration: 0.75, usesShortestUnitArc: true
        )
        settle.timingFunction = { t in
            // A small overshoot gives the icon a soft spring-like return.
            let p = t - 1
            return 1 + 2.4 * p * p * p + 1.4 * p * p
        }
        return settle
    }

    @objc private func tapEdge(_ tap: UITapGestureRecognizer) {
        guard let point = artworkPoint(at: tap.location(in: self)) else { return }
        tapFeedback.impactOccurred(intensity: 0.65)
        guard let edge = edge(at: point) else { return }
        activate(edge)
    }

    private func activate(_ edge: Edge) {
        guard !reduceMotion, icon.action(forKey: Self.spinActionKey) == nil else { return }
        let visibleAngles = icon.presentation.eulerAngles
        icon.removeAllActions()
        icon.eulerAngles = visibleAngles
        if (edge == .left || edge == .right), primedEdge != nil {
            primedEdge = nil
            let direction: CGFloat = edge == .left ? -1 : 1
            let turn = SCNAction.rotateBy(x: 0, y: direction * .pi * 2, z: 0, duration: 1.05)
            turn.timingMode = .easeInEaseOut
            // Continue just past the front before the damped return, rather than
            // stopping dead at the end of the full revolution.
            let coast = SCNAction.rotateBy(x: 0, y: direction * 0.12, z: 0, duration: 0.12)
            coast.timingMode = .easeOut
            icon.runAction(.sequence([turn, coast, settleAction()]), forKey: Self.spinActionKey)
        } else {
            primedEdge = (edge == .left || edge == .right) ? edge : nil
            let x: CGFloat = edge == .top ? -0.18 : (edge == .bottom ? 0.18 : 0)
            let y: CGFloat = edge == .left ? -0.18 : (edge == .right ? 0.18 : 0)
            let nudge = SCNAction.rotateTo(x: x, y: y, z: 0, duration: 0.12, usesShortestUnitArc: true)
            nudge.timingMode = .easeOut
            icon.runAction(.sequence([nudge, settleAction()]))
        }
    }

    override func accessibilityActivate() -> Bool {
        tapFeedback.impactOccurred(intensity: 0.65)
        activate(.right)
        return true
    }
}
