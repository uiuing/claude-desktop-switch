import AppKit

/// The project's public home, linked from the sidebar, the menu bar panel and Settings.
enum ProjectLink {
    static let repository = URL(string: "https://github.com/uiuing/claude-desktop-switch")!
    static let symbol = "chevron.left.forwardslash.chevron.right"
    static func open() { NSWorkspace.shared.open(repository) }
}
