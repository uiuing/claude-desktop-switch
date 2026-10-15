import AppKit
import SwiftUI
import SwitchCore

struct MenuBarQuotaLabel: View {
    let quota: String
    let reminder: SwitchReminder?
    let icon: NSImage

    private var warning: SwitchReminder? {
        // Reviewing a reminder silences notifications, not the still-actionable quota state.
        reminder.flatMap { $0.kind == .expiring ? nil : $0 }
    }
    var description: String {
        let remaining = L10n.tr("Claude Switch, current account session limit remaining: {0}", L10n.argument(quota))
        if let warning {
            let reason = warning.kind == .weeklyLow ? warning.title + "\n" + warning.detail : warning.title
            return [reason, remaining, L10n.tr("Another account is available. Click to review the switch.")].joined(separator: "\n")
        }
        return reminder?.needsReview == true ? L10n.tr("Recommendation available. Click to review the switch.") : remaining
    }
    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: icon)
            if let warning {
                if warning.kind == .weeklyLow { Text(quota).monospacedDigit() }
                Image(nsImage: MenuBarQuotaBadge.image(quota: warning.kind == .weeklyLow
                    ? L10n.tr("menuBar.weeklyRemaining", L10n.argument(warning.remaining)) : warning.remaining,
                    exhausted: warning.exhausted))
                    .renderingMode(.original)
            } else {
                Text(quota).monospacedDigit()
                if reminder?.needsReview == true {
                    Image(systemName: "arrow.left.arrow.right.circle.fill").foregroundStyle(.orange)
                }
            }
        }
        .help(description)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
    }
}

/// A non-template image keeps the badge's fill and white content in the system status item.
@MainActor
enum MenuBarQuotaBadge {
    static func image(quota: String, exhausted: Bool) -> NSImage {
        let text = NSAttributedString(string: quota, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let textSize = text.size()
        let height: CGFloat = 18, padding: CGFloat = 6, gap: CGFloat = 4, arrowWidth: CGFloat = 11
        let size = NSSize(width: ceil(textSize.width) + padding * 2 + gap + arrowWidth, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            // Fixed fills keep white text legible on both light and dark menu bars.
            (exhausted ? NSColor(srgbRed: 0.78, green: 0.16, blue: 0.18, alpha: 1)
                       : NSColor(srgbRed: 0.72, green: 0.34, blue: 0.02, alpha: 1)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            text.draw(at: NSPoint(x: padding, y: (height - textSize.height) / 2))

            let x = rect.maxX - padding - arrowWidth
            let arrows = NSBezierPath()
            arrows.lineWidth = 1.3; arrows.lineCapStyle = .round; arrows.lineJoinStyle = .round
            arrows.move(to: NSPoint(x: x, y: 12))
            arrows.line(to: NSPoint(x: x + arrowWidth, y: 12))
            arrows.move(to: NSPoint(x: x + arrowWidth - 3, y: 15))
            arrows.line(to: NSPoint(x: x + arrowWidth, y: 12))
            arrows.line(to: NSPoint(x: x + arrowWidth - 3, y: 9))
            arrows.move(to: NSPoint(x: x + arrowWidth, y: 6))
            arrows.line(to: NSPoint(x: x, y: 6))
            arrows.move(to: NSPoint(x: x + 3, y: 9))
            arrows.line(to: NSPoint(x: x, y: 6))
            arrows.line(to: NSPoint(x: x + 3, y: 3))
            NSColor.white.setStroke(); arrows.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
