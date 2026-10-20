import AppKit

enum TrackingAnimation: String, CaseIterable {
    case sparkles = "Sparkles"
    case munch = "Munching Cracker"
    case none = "None"

    var frames: [NSImage] {
        switch self {
        case .sparkles, .none: MenuBarIcon.sparkleFrames
        case .munch: MenuBarIcon.munchFrames
        }
    }

    var frameInterval: TimeInterval {
        self == .munch ? 0.6 : 0.4
    }
}

/// Menu bar images. All are template images so they follow the system menu bar color.
enum MenuBarIcon {
    static let stopped = grahamCracker(bites: [])

    /// Twinkling sparkles: each frame, a different star swells.
    static let sparkleFrames: [NSImage] = [
        (1.0, 0.55, 0.55),
        (0.88, 1.1, 0.55),
        (0.88, 0.55, 1.25),
        (1.05, 0.8, 0.8),
    ].map { sparkles(big: $0.0, top: $0.1, bottom: $0.2) }

    /// The cracker getting eaten from the right, one bite per frame. Every frame has a bite so none matches `stopped`.
    static let munchFrames: [NSImage] = {
        let bites: [Bite] = [
            Bite(x: 18.5, y: 12.5, radius: 4.2),
            Bite(x: 19.2, y: 6, radius: 3.6),
            Bite(x: 18.5, y: -0.5, radius: 4.2),
            // Big chomp: clears the right side, leaving a scalloped edge.
            Bite(x: 22, y: 6, radius: 9),
            Bite(x: 14.5, y: 11.5, radius: 3),
            Bite(x: 13.5, y: 6.5, radius: 3),
            Bite(x: 14.5, y: 0.5, radius: 3),
            // Final chomp past the snap line.
            Bite(x: 15.5, y: 6, radius: 9),
            Bite(x: 8, y: 11.5, radius: 3),
            Bite(x: 7, y: 6.5, radius: 3),
            Bite(x: 8, y: 0.5, radius: 3),
        ]
        return [2, 3, 7, 11].map { grahamCracker(bites: Array(bites.prefix($0))) }
    }()

    struct Bite {
        /// Center relative to the cracker's bottom-left corner (cracker is 18×12 pt).
        let x: CGFloat
        let y: CGFloat
        let radius: CGFloat
    }

    static func grahamCracker(bites: [Bite]) -> NSImage {
        let image = NSImage(size: NSSize(width: 21, height: 14), flipped: false) { _ in
            let body = NSRect(x: 1.5, y: 1, width: 18, height: 12)
            let path = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2)

            // Snap line down the middle.
            for y in stride(from: body.minY + 1.5, through: body.maxY - 1.5, by: 1.5) {
                path.appendOval(in: circle(x: body.midX, y: y, radius: 0.4))
            }
            // Docking holes: 2×2 on each half.
            let halfWidth = body.width / 2
            for half in 0..<2 {
                for column in 1...2 {
                    for row in 1...2 {
                        let x = body.minX + CGFloat(half) * halfWidth + halfWidth * CGFloat(column) / 3
                        let y = body.minY + body.height * CGFloat(row) / 3
                        path.appendOval(in: circle(x: x, y: y, radius: 0.7))
                    }
                }
            }
            path.windingRule = .evenOdd
            NSColor.black.setFill()
            path.fill()

            NSGraphicsContext.current?.compositingOperation = .clear
            for bite in bites {
                NSBezierPath(ovalIn: circle(x: body.minX + bite.x, y: body.minY + bite.y, radius: bite.radius)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = bites.isEmpty ? "Stopped" : "Tracking"
        return image
    }

    private static func sparkles(big: CGFloat, top: CGFloat, bottom: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            star(x: 7.5, y: 7.5, radius: 6.5 * big).fill()
            star(x: 15.5, y: 12, radius: 3.2 * top).fill()
            star(x: 16, y: 3.5, radius: 2.6 * bottom).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tracking"
        return image
    }

    /// Four-pointed star with concave sides.
    private static func star(x: CGFloat, y: CGFloat, radius: CGFloat) -> NSBezierPath {
        let pinch = radius * 0.18
        let points = [
            NSPoint(x: x, y: y + radius), NSPoint(x: x + radius, y: y),
            NSPoint(x: x, y: y - radius), NSPoint(x: x - radius, y: y),
        ]
        let controls = [
            NSPoint(x: x + pinch, y: y + pinch), NSPoint(x: x + pinch, y: y - pinch),
            NSPoint(x: x - pinch, y: y - pinch), NSPoint(x: x - pinch, y: y + pinch),
        ]
        let path = NSBezierPath()
        path.move(to: points[0])
        for i in 0..<4 {
            path.curve(to: points[(i + 1) % 4], controlPoint1: controls[i], controlPoint2: controls[i])
        }
        path.close()
        return path
    }

    private static func circle(x: CGFloat, y: CGFloat, radius: CGFloat) -> NSRect {
        NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
    }
}
