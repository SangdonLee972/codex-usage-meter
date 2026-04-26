import AppKit

func remainingStateLabel(for remainingPercent: Double) -> String {
    switch remainingPercent {
    case 65...:
        return "plenty"
    case 35..<65:
        return "steady"
    case 15..<35:
        return "low"
    case 0..<15:
        return "critical"
    default:
        return "empty"
    }
}

func remainingStateColor(for remainingPercent: Double) -> NSColor {
    switch remainingPercent {
    case 65...:
        return .systemGreen
    case 35..<65:
        return .systemBlue
    case 15..<35:
        return .systemOrange
    default:
        return .systemRed
    }
}

enum StatusIconRenderer {
    static let width: CGFloat = 22

    /// Stack one bar per provider. `remaining` is in display order (top → bottom),
    /// `nil` entries render an empty track so missing data is visible at a glance.
    static func makeIcon(remaining: [Double?]) -> NSImage {
        let count = max(1, remaining.count)
        let layout = layoutFor(barCount: count)
        let image = NSImage(size: NSSize(width: width, height: layout.totalHeight))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.shouldAntialias = true

        let inset: CGFloat = 1.5
        let barWidth = width - 2 * inset

        for (index, value) in remaining.enumerated() {
            let y = layout.bottomY(at: index, total: count)
            drawBar(x: inset, y: y, width: barWidth, height: layout.barHeight, remaining: value)
        }
        return image
    }

    private struct Layout {
        let barHeight: CGFloat
        let gap: CGFloat
        let totalHeight: CGFloat

        func bottomY(at index: Int, total: Int) -> CGFloat {
            // index 0 = top bar
            let inverted = total - 1 - index
            return CGFloat(inverted) * (barHeight + gap)
        }
    }

    private static func layoutFor(barCount: Int) -> Layout {
        switch barCount {
        case 1:    return Layout(barHeight: 8, gap: 0, totalHeight: 8)
        case 2:    return Layout(barHeight: 5, gap: 2, totalHeight: 12)
        case 3:    return Layout(barHeight: 4, gap: 1.5, totalHeight: 15)
        default:   return Layout(barHeight: 3, gap: 1, totalHeight: CGFloat(barCount) * 3 + CGFloat(barCount - 1))
        }
    }

    private static func drawBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, remaining: Double?) {
        let radius = height / 2
        let track = NSRect(x: x, y: y, width: width, height: height)
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        guard let remaining else { return }
        let pct = max(0, min(100, remaining))
        guard pct > 0 else { return }
        let fillWidth = max(height, width * CGFloat(pct / 100))
        let fillRect = NSRect(x: x, y: y, width: fillWidth, height: height)
        remainingStateColor(for: pct).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }
}
