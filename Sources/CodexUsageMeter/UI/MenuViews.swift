import AppKit

final class SectionHeaderView: NSView {
    private let title: String
    private let icon: ProviderIcon?

    override var isFlipped: Bool { true }

    init(title: String, icon: ProviderIcon? = nil) {
        self.title = title
        self.icon = icon
        super.init(frame: NSRect(x: 0, y: 0, width: 314, height: 20))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let textColor = NSColor.secondaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: textColor,
            .kern: 0.9
        ]

        let leading: CGFloat = 14
        var textX = leading

        if let icon, let image = icon.image(size: 12, tint: textColor) {
            let iconRect = NSRect(x: leading, y: 4, width: 12, height: 12)
            image.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
            textX = iconRect.maxX + 6
        }

        let textWidth = max(0, 300 - textX)
        title.uppercased().draw(in: NSRect(x: textX, y: 5, width: textWidth, height: 14), withAttributes: attrs)
    }
}

final class TokenSummaryView: NSView {
    private let columns: [(label: String, value: String)]

    override var isFlipped: Bool { true }

    init(lastTurn: String, recent: String, latestCall: String) {
        self.columns = [
            ("LAST TURN", lastTurn),
            ("LAST 3 MIN", recent),
            ("LATEST CALL", latestCall)
        ]
        super.init(frame: NSRect(x: 0, y: 0, width: 314, height: 42))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.5
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]

        let totalWidth: CGFloat = 286
        let columnWidth = totalWidth / CGFloat(columns.count)
        let leftMargin: CGFloat = 14

        for (index, column) in columns.enumerated() {
            let x = leftMargin + CGFloat(index) * columnWidth
            column.label.draw(
                in: NSRect(x: x, y: 4, width: columnWidth, height: 12),
                withAttributes: labelAttrs)
            column.value.draw(
                in: NSRect(x: x, y: 19, width: columnWidth, height: 16),
                withAttributes: valueAttrs)
        }
    }
}

final class FooterMetaView: NSView {
    private let text: String

    override var isFlipped: Bool { true }

    init(text: String) {
        self.text = text
        super.init(frame: NSRect(x: 0, y: 0, width: 314, height: 18))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        text.draw(in: NSRect(x: 14, y: 3, width: 286, height: 13), withAttributes: attrs)
    }
}

final class GaugeMenuView: NSView {
    private let title: String
    private let subtitle: String
    private let fraction: CGFloat
    private let state: String
    private let percentage: String
    private let fillColor: NSColor

    override var isFlipped: Bool { true }

    init(title: String, subtitle: String, remainingPercent: Double) {
        self.title = title
        self.subtitle = subtitle
        self.fraction = CGFloat(min(100, max(0, remainingPercent)) / 100)
        self.state = remainingStateLabel(for: remainingPercent)
        self.percentage = "\(Int(remainingPercent.rounded()))% left"
        self.fillColor = remainingStateColor(for: remainingPercent)
        super.init(frame: NSRect(x: 0, y: 0, width: 314, height: 58))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let stateAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: fillColor
        ]
        let percentageAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        title.draw(in: NSRect(x: 14, y: 7, width: 135, height: 18), withAttributes: titleAttributes)
        percentage.draw(in: NSRect(x: 159, y: 8, width: 70, height: 16), withAttributes: percentageAttributes)
        state.draw(in: NSRect(x: 232, y: 8, width: 68, height: 16), withAttributes: stateAttributes)

        let track = NSRect(x: 14, y: 29, width: 286, height: 10)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()

        if fraction > 0 {
            let fillWidth = max(3, track.width * fraction)
            let fill = NSRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height)
            fillColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 5, yRadius: 5).fill()
        }

        subtitle.draw(in: NSRect(x: 14, y: 42, width: 286, height: 14), withAttributes: subtitleAttributes)
    }
}
