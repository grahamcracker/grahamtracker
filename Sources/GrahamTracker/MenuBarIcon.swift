import AppKit

enum MenuBarIcon {
    static let running: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Tracking")!
            .withSymbolConfiguration(config)!
        image.isTemplate = true
        return image
    }()

    static let stopped = grahamCracker(biteRadius: 7, columns: 2, rows: 2)

    /// A graham cracker with a bite out of the corner. Holes and the bite are cut out so it works as a template image.
    static func grahamCracker(biteRadius: CGFloat, columns: Int, rows: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 21, height: 14), flipped: false) { _ in
            let body = NSRect(x: 1.5, y: 1, width: 18, height: 12)
            let path = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2)
            func circle(x: CGFloat, y: CGFloat, radius: CGFloat) -> NSRect {
                NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            }

            // Snap line down the middle.
            for y in stride(from: body.minY + 1.5, through: body.maxY - 1.5, by: 1.5) {
                path.appendOval(in: circle(x: body.midX, y: y, radius: 0.4))
            }
            // Docking holes on each half.
            let halfWidth = body.width / 2
            for half in 0..<2 {
                for column in 1...columns {
                    for row in 1...rows {
                        let x = body.minX + CGFloat(half) * halfWidth + halfWidth * CGFloat(column) / CGFloat(columns + 1)
                        let y = body.minY + body.height * CGFloat(row) / CGFloat(rows + 1)
                        path.appendOval(in: circle(x: x, y: y, radius: 0.7))
                    }
                }
            }
            path.windingRule = .evenOdd
            NSColor.black.setFill()
            path.fill()

            // Scalloped bite out of the top-right corner.
            let scallop = biteRadius * 0.43
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: circle(x: body.maxX + 0.5, y: body.maxY + 0.5, radius: biteRadius)).fill()
            NSBezierPath(ovalIn: circle(x: body.maxX + 1.0, y: body.maxY - biteRadius, radius: scallop)).fill()
            NSBezierPath(ovalIn: circle(x: body.maxX - biteRadius - 0.3, y: body.maxY + 1.0, radius: scallop)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Stopped"
        return image
    }
}
