import AppKit

enum ProviderIcon {
    case codex
    case claude
    case gemini

    var resourceName: String {
        switch self {
        case .codex:  return "provider-codex"
        case .claude: return "provider-claude"
        case .gemini: return "provider-gemini"
        }
    }

    func image(size: CGFloat, tint: NSColor) -> NSImage? {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "svg"),
              let base = NSImage(contentsOf: url) else {
            return nil
        }
        let target = NSSize(width: size, height: size)
        let tinted = NSImage(size: target, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return tinted
    }
}
