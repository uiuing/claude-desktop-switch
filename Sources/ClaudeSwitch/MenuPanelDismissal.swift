import AppKit

@MainActor
enum MenuPanelDismissal {
    /// MenuBarExtra owns both its window and its selected state. Closing only the NSWindow
    /// leaves SwiftUI's presentation state behind, so the next click merely toggles it off.
    static func close(_ panel: NSWindow?, in windows: [NSWindow]? = nil) {
        guard let panel, panel.isVisible else { return }
        let buttons = (windows ?? NSApp.windows).flatMap { $0.contentView.map(statusButtons) ?? [] }
        // The app has one MenuBarExtra. Never dispatch an action to an ambiguous status item.
        if buttons.count == 1, let button = buttons.first, button.isEnabled, button.action != nil {
            button.performClick(nil)
        } else {
            // Offscreen previews and tests can host MenuPanel in a plain window without a status item.
            panel.close()
        }
    }

    private static func statusButtons(in view: NSView) -> [NSStatusBarButton] {
        if let button = view as? NSStatusBarButton { return [button] }
        return view.subviews.flatMap(statusButtons)
    }
}
