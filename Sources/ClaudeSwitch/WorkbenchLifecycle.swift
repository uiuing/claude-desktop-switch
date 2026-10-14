import AppKit
import SwiftUI

/// Only the workbench controls Dock visibility. Status-item panels and sheets
/// must not promote the app or keep its Dock icon alive after the workbench closes.
@MainActor
final class WorkbenchLifecycle: NSObject {
    static let shared = WorkbenchLifecycle()
    private weak var workbench: NSWindow?
    private var generation: UInt64 = 0
    private var terminating = false
    /// Off: no status item, and closing the workbench quits the app.
    static let showInMenuBarKey = "showInMenuBar"
    private var keepsRunningInMenuBar: Bool {
        UserDefaults.standard.object(forKey: Self.showInMenuBarKey) as? Bool ?? true
    }
    /// Open and at least partly visible: not closed, minimized, on another Space or fully covered.
    var workbenchOnScreen: Bool { workbench.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false }

    func register(_ window: NSWindow) {
        guard workbench !== window else { return }
        NotificationCenter.default.removeObserver(self)
        workbench = window
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: window)
        center.addObserver(self, selector: #selector(windowDidPresent(_:)),
                           name: NSWindow.didBecomeMainNotification, object: window)
        center.addObserver(self, selector: #selector(windowDidPresent(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: window)
        prepareToOpen()
    }

    func prepareToOpen() {
        guard !terminating else { return }
        generation &+= 1
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// Closes the workbench once its sheet has finished dismissing; the app stays in the menu bar.
    func closeWorkbench(attempts: Int = 20) {
        guard let window = workbench, window.isVisible else { return }
        if window.attachedSheet != nil, attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.closeWorkbench(attempts: attempts - 1) }
            return
        }
        window.close()
    }

    func willTerminate() {
        terminating = true
        generation &+= 1
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowDidPresent(_ notification: Notification) {
        guard notification.object as? NSWindow === workbench else { return }
        prepareToOpen()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard !terminating, let window = notification.object as? NSWindow,
              window === workbench else { return }
        generation &+= 1
        let closingGeneration = generation
        // willClose arrives before AppKit finishes closing the window. Defer the
        // policy change, and discard it if the workbench reopens in the meantime.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, !self.terminating, self.generation == closingGeneration else { return }
            guard window?.isVisible != true, window?.isMiniaturized != true else { return }
            guard self.keepsRunningInMenuBar else { NSApp.terminate(nil); return }
            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

/// Observe the actual SwiftUI workbench without replacing its NSWindowDelegate.
struct WorkbenchWindowObserver: NSViewRepresentable {
    final class Attachment: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.contentMinSize = NSSize(width: 920, height: 620)
            WorkbenchLifecycle.shared.register(window)
        }
    }
    func makeNSView(context: Context) -> Attachment { Attachment() }
    func updateNSView(_ view: Attachment, context: Context) {}
}
