import AppKit
import SwiftUI
import SwitchCore

/// MenuBarExtra extracts a native title and image from its label; it does not lay out arbitrary
/// HStacks like a normal SwiftUI view. Supply one image so every quota and task segment survives.
@MainActor
enum MenuBarStatusImage {
    static func image(quota: String, reminder: SwitchReminder?, tasks: CodeTaskSnapshot?, icon: NSImage,
                      colorScheme: ColorScheme, rotation: Double = 0) -> NSImage {
        let content = HStack(spacing: 7) {
            MenuBarQuotaLabel(quota: quota, reminder: reminder, icon: icon)
            if let tasks, tasks.availability == .ready { MenuBarTaskLabel(snapshot: tasks, rotation: rotation) }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
        .environment(\.colorScheme, colorScheme)
        .fixedSize()
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? fallback(quota: quota, tasks: tasks, colorScheme: colorScheme)
        image.isTemplate = false
        return image
    }
    /// Render each small frame once per quota/count/appearance change, then reuse it on animation ticks.
    @MainActor final class Cache {
        private struct Key: Equatable {
            var quota: String
            var reminder: SwitchReminder?
            var running: Int?
            var waiting: Int?
            var dark: Bool
            var locale: String
            var scale: CGFloat
            var icon: ObjectIdentifier
        }
        private var key: Key?
        private var frames: [Int: NSImage] = [:]
        func image(quota: String, reminder: SwitchReminder?, tasks: CodeTaskSnapshot?, icon: NSImage,
                   colorScheme: ColorScheme, frame: Int) -> NSImage {
            let current = Key(quota: quota, reminder: reminder, running: tasks?.running, waiting: tasks?.waiting,
                              dark: colorScheme == .dark, locale: L10n.locale.identifier,
                              scale: NSScreen.main?.backingScaleFactor ?? 2, icon: ObjectIdentifier(icon))
            if key != current { key = current; frames = [:] }
            let index = (tasks?.running ?? 0) > 0 ? max(0, frame) % MenuBarTaskAnimation.frameCount : 0
            if let image = frames[index] { return image }
            let image = MenuBarStatusImage.image(quota: quota, reminder: reminder, tasks: tasks, icon: icon,
                                                colorScheme: colorScheme, rotation: Double(index) * 360 / Double(MenuBarTaskAnimation.frameCount))
            frames[index] = image
            return image
        }
    }
    static func description(quota: String, reminder: SwitchReminder?, tasks: CodeTaskSnapshot?) -> String {
        let quotaDescription = MenuBarQuotaLabel(quota: quota, reminder: reminder, icon: NSImage()).description
        guard let tasks, tasks.availability == .ready else { return quotaDescription }
        return quotaDescription + "\n" + L10n.tr("Claude Code tasks") + ": " + tasks.detail
    }
    private static func fallback(quota: String, tasks: CodeTaskSnapshot?, colorScheme: ColorScheme) -> NSImage {
        let summary = quota + (tasks?.availability == .ready ? "  ·  " + (tasks?.detail ?? "") : "")
        let text = NSAttributedString(string: summary, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: colorScheme == .dark ? NSColor.white : NSColor.black,
        ])
        return NSImage(size: text.size(), flipped: false) { _ in text.draw(at: .zero); return true }
    }
}
