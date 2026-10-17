import AppKit
import FootprintCore
import SwiftUI

enum TrayIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: true) { _ in
            drawMac(color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }()

    static func image(for pressure: MemoryPressureState) -> NSImage {
        switch pressure {
        case .warning: return warningImage
        case .critical: return criticalImage
        default: return image
        }
    }

    private static let warningImage = alertImage(NSColor(Palette.amber))
    private static let criticalImage = alertImage(NSColor(Palette.coral))

    private static func alertImage(_ dot: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: true) { _ in
            drawMac(color: .labelColor)
            let ring = NSBezierPath(ovalIn: NSRect(x: 14.5, y: 0, width: 7.5, height: 7.5))
            NSColor.windowBackgroundColor.setFill()
            ring.fill()
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: 15.5, y: 1, width: 5.5, height: 5.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawMac(color: NSColor) {
        color.setStroke()
        color.setFill()

        let lid = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 2, width: 13, height: 9.25), xRadius: 1.8, yRadius: 1.8)
        lid.lineWidth = 1.25
        lid.stroke()

        let base = NSBezierPath(roundedRect: NSRect(x: 1, y: 12.5, width: 18, height: 1.5), xRadius: 0.75, yRadius: 0.75)
        base.fill()

        let pulse = NSBezierPath()
        pulse.move(to: NSPoint(x: 5.5, y: 6.75))
        pulse.line(to: NSPoint(x: 7.75, y: 6.75))
        pulse.line(to: NSPoint(x: 9, y: 4.25))
        pulse.line(to: NSPoint(x: 10.75, y: 9.25))
        pulse.line(to: NSPoint(x: 12, y: 6.75))
        pulse.line(to: NSPoint(x: 14.5, y: 6.75))
        pulse.lineWidth = 1.2
        pulse.lineCapStyle = .round
        pulse.lineJoinStyle = .round
        pulse.stroke()
    }
}

struct TrayLabel: View {
    @ObservedObject var memory: SystemMonitor

    var body: some View {
        Image(nsImage: TrayIcon.image(for: worst))
            .accessibilityLabel(worst == .normal || worst == .unknown ? "Macin" : "Macin needs attention")
    }

    private var worst: MemoryPressureState {
        if memory.pressure == .critical || memory.thermal == .critical { return .critical }
        if memory.pressure == .warning || memory.thermal == .serious { return .warning }
        return memory.pressure
    }
}
