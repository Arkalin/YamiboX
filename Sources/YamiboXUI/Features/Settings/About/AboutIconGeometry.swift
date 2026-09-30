import UIKit

/// Generated from the icon's original vector contours by split-app-icon.cjs.
struct AboutIconGeometry: Decodable, Sendable {
    let canvasSize: CGFloat
    let layers: [Layer]

    struct Layer: Decodable, Sendable {
        let name: String
        let extrusionDepth: CGFloat
        let commands: [Command]

        func makePath(canvasSize: CGFloat) -> UIBezierPath {
            let path = UIBezierPath()
            path.usesEvenOddFillRule = true
            path.flatness = 0.001
            let scale = 2 / canvasSize
            func point(_ values: [CGFloat], at index: Int) -> CGPoint {
                CGPoint(x: values[index] * scale - 1, y: 1 - values[index + 1] * scale)
            }
            for command in commands {
                switch command.kind {
                case .move:
                    // SVG fill implicitly closes each subpath. Close explicitly
                    // so SceneKit also extrudes the seams and preserves holes.
                    if !path.isEmpty { path.close() }
                    path.move(to: point(command.values, at: 0))
                case .line:
                    path.addLine(to: point(command.values, at: 0))
                case .curve:
                    path.addCurve(
                        to: point(command.values, at: 4),
                        controlPoint1: point(command.values, at: 0),
                        controlPoint2: point(command.values, at: 2)
                    )
                case .close:
                    path.close()
                }
            }
            path.close()
            return path
        }
    }

    struct Command: Decodable, Sendable {
        enum Kind: String, Decodable, Sendable { case move, line, curve, close }
        let kind: Kind
        let values: [CGFloat]

        var isValid: Bool {
            let count: Int
            switch kind {
            case .move, .line: count = 2
            case .curve: count = 6
            case .close: count = 0
            }
            return values.count == count && values.allSatisfy(\.isFinite)
        }
    }

    static let bundled: Self? = {
        guard let url = Bundle.module.url(forResource: "AboutIconGeometry", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let geometry = try? JSONDecoder().decode(Self.self, from: data),
              geometry.canvasSize.isFinite, geometry.canvasSize > 0,
              !geometry.layers.isEmpty,
              geometry.layers.allSatisfy({ layer in
                  layer.extrusionDepth.isFinite && layer.extrusionDepth > 0
                      && layer.commands.first?.kind == .move
                      && layer.commands.allSatisfy(\.isValid)
              }) else { return nil }
        return geometry
    }()
}
