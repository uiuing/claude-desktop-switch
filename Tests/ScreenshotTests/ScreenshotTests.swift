import AppKit
import SwiftUI
import XCTest
@testable import ClaudeSwitch
import SwitchCore

/// Renders the README images from `--demo` data. No real account data is involved.
/// Run through `scripts/screenshots.sh`; skipped unless CLAUDE_SWITCH_SCREENSHOTS names an output folder.
@MainActor
final class ScreenshotTests: XCTestCase {
    private static let languages = ["en", "zh-Hans", "zh-Hant", "ja"]
    nonisolated private static let windowSize = NSSize(width: 1080, height: 740)
    /// Releasing a window with a bridged SwiftUI toolbar mid-run makes AppKit raise; keep them until exit.
    private static var windows: [NSWindow] = []
    private var output: URL!

    func testRenderReadmeImages() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to an output folder to render the README images.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))

        for language in Self.languages {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let state = AppState(demo: true)
            spin(0.3)
            // The demo's "sample data" notice is for people running --demo, not for screenshots.
            state.inventory?.warnings = []
            let status = state.fiveHourQuota?.percentageText ?? "—"
            for dark in [false, true] {
                let mode = dark ? "dark" : "light"
                state.page = .accounts
                state.selectedSessionIDs = []
                let accounts = try captureWorkbench(state, dark: dark)
                let menu = try captureMenu(state, dark: dark)
                try save(render(HeroImage(window: accounts, menu: menu, status: status, dark: dark), size: HeroImage.size),
                         "hero-\(language)-\(mode)", maxWidth: 1800, jpeg: true)
                guard language == "en" else { continue }
                try save(accounts, "accounts-\(mode)", maxWidth: 1600)
                try save(menu, "menu-\(mode)", maxWidth: 700)
                state.page = .conversations
                state.selectedSessionIDs = ["demo-1"]
                try save(captureWorkbench(state, dark: dark), "conversations-\(mode)", maxWidth: 1600)
                state.page = .usage
                try save(captureWorkbench(state, dark: dark, size: NSSize(width: 1080, height: 980), settle: 2),
                         "usage-\(mode)", maxWidth: 1600)
                if !dark {
                    try save(render(SocialPreview(menu: menu), size: NSSize(width: 1280, height: 640), scale: 1),
                             "social-preview", maxWidth: 1280)
                }
            }
        }
    }

    // MARK: Capture

    func testRenderQuotaSettings() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render quota settings.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        for language in ["en", "de", "zh-Hans"] {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let state = AppState(demo: true)
            state.page = .settings
            try save(captureWorkbench(state, dark: false, size: NSSize(width: 1080, height: 900), settle: 3),
                     "quota-settings-\(language)", maxWidth: 1600)
        }
    }

    func testRenderQuotaRecoveryStates() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render quota recovery states.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        for language in ["en", "de"] {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let state = AppState(demo: true)
            state.inventory?.warnings = []
            for (index, account) in state.accounts.enumerated() {
                guard var snapshot = state.library.usage[account.id] else { continue }
                let date = Date().addingTimeInterval(-3600)
                snapshot.observedAt = date
                for i in snapshot.windows.indices {
                    snapshot.windows[i].observedAt = date
                    if index == 0 { snapshot.windows[i].resetsAt = Date().addingTimeInterval(-60) }
                }
                state.library.usage[account.id] = snapshot
            }
            if let id = state.activeID { state.usageNotices[id] = L10n.tr("Waiting for Claude to publish its login credentials.") }
            try save(captureWorkbench(state, dark: false), "quota-states-\(language)", maxWidth: 1600)
            try save(captureMenu(state, dark: false), "quota-menu-\(language)", maxWidth: 700)
        }
    }

    private func captureWorkbench(_ state: AppState, dark: Bool, size: NSSize = windowSize, settle: TimeInterval = 1.2) throws -> NSImage {
        let controller = NSHostingController(rootView: MainWindow().environment(state).environment(\.locale, L10n.locale)
            .environment(\.controlActiveState, .key))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let frame = NSRect(origin: NSPoint(x: -6000, y: 200), size: size)
        let window = ActiveWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.contentViewController = controller
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        Self.windows.append(window)
        defer { window.orderOut(nil) }
        spin(settle)
        window.display()
        spin(0.2)
        return try capture(window)
    }

    private func captureMenu(_ state: AppState, dark: Bool) throws -> NSImage {
        let content = MenuPanel().environment(state).environment(\.locale, L10n.locale)
            .background(VisualEffect()).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        let view = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: 200, width: 400, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.setContentSize(view.fittingSize)
        window.orderFrontRegardless()
        Self.windows.append(window)
        defer { window.orderOut(nil) }
        spin(1)
        return try capture(window)
    }

    private func capture(_ window: NSWindow) throws -> NSImage {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else { throw CaptureError.windowCapture }
        return NSImage(cgImage: image, size: window.frame.size)
    }

    private func render<Content: View>(_ view: Content, size: NSSize, scale: CGFloat = 2) throws -> NSImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let image = renderer.cgImage else { throw CaptureError.composition }
        return NSImage(cgImage: image, size: size)
    }

    /// Opaque compositions are written as JPEG to keep the repository small; screenshots keep their transparent corners as PNG.
    private func save(_ image: NSImage, _ name: String, maxWidth: CGFloat, jpeg: Bool = false) throws {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CaptureError.encoding }
        let ratio = min(1, maxWidth / CGFloat(source.width))
        let width = Int((CGFloat(source.width) * ratio).rounded()), height = Int((CGFloat(source.height) * ratio).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.encoding }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: jpeg ? .jpeg : .png,
                                                                          properties: jpeg ? [.compressionFactor: 0.9] : [:])
        else { throw CaptureError.encoding }
        try data.write(to: output.appendingPathComponent(name + (jpeg ? ".jpg" : ".png")))
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private enum CaptureError: Error { case windowCapture, composition, encoding }
}

/// Draws as the focused window, so controls and window buttons use their active colors without stealing focus.
private final class ActiveWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func _hasMainAppearance() -> Bool { true }
}

private extension NSApplication {
    @objc var screenshotAlwaysActive: Bool { true }
    /// Within this test process only, report the app as active so AppKit draws active window chrome.
    static let pretendActive: Void = {
        guard let original = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)),
              let replacement = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.screenshotAlwaysActive))
        else { return }
        method_exchangeImplementations(original, replacement)
    }()
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover; view.blendingMode = .withinWindow; view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Soft wallpaper with warm glows, shared by the hero and the social preview.
private struct Backdrop: View {
    let dark: Bool
    var body: some View {
        ZStack {
            LinearGradient(colors: dark ? [Color(hex: 0x241915), Color(hex: 0x141519)] : [Color(hex: 0xFCEFE6), Color(hex: 0xEFE6F4)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { proxy in
                let size = proxy.size
                Circle().fill(Palette.brand.opacity(dark ? 0.42 : 0.34)).frame(width: size.width * 0.55)
                    .blur(radius: 120).position(x: size.width * 0.86, y: size.height * 0.12)
                Circle().fill(Color(hex: dark ? 0x6B3FA0 : 0xC9B8F0).opacity(dark ? 0.35 : 0.55)).frame(width: size.width * 0.5)
                    .blur(radius: 140).position(x: size.width * 0.12, y: size.height * 0.95)
                Circle().fill(Color(hex: dark ? 0xA0522D : 0xFFD3B0).opacity(dark ? 0.25 : 0.6)).frame(width: size.width * 0.4)
                    .blur(radius: 120).position(x: size.width * 0.3, y: size.height * 0.1)
            }
        }
    }
}

/// The main window with the menu bar panel dropping from its status item.
private struct HeroImage: View {
    static let size = NSSize(width: 1440, height: 880)
    let window: NSImage
    let menu: NSImage
    let status: String
    let dark: Bool
    private var panelX: CGFloat { Self.size.width - menu.size.width - 64 }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Backdrop(dark: dark)
            menuBar
            Image(nsImage: window).resizable().frame(width: window.size.width * 0.95, height: window.size.height * 0.95)
                .shadow(color: .black.opacity(dark ? 0.6 : 0.24), radius: 34, y: 18)
                .offset(x: 56, y: 92)
            Image(nsImage: menu).resizable().frame(width: menu.size.width, height: menu.size.height)
                .shadow(color: .black.opacity(dark ? 0.55 : 0.22), radius: 26, y: 12)
                .offset(x: panelX, y: 36)
        }
        .environment(\.colorScheme, dark ? .dark : .light)
    }
    private var menuBar: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(dark ? Color.black.opacity(0.38) : Color.white.opacity(0.5)).frame(height: 30)
            HStack(spacing: 18) {
                HStack(spacing: 5) {
                    Image(nsImage: StatusIcon.image).renderingMode(.template).resizable().frame(width: 18, height: 18)
                    Text(status).monospacedDigit()
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.primary.opacity(dark ? 0.2 : 0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Image(systemName: "magnifyingglass")
            }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(dark ? .white : .black)
            .offset(x: panelX + 6)
        }
    }
}

/// 1280 × 640 card for the repository's social preview.
private struct SocialPreview: View {
    let menu: NSImage
    var body: some View {
        ZStack {
            Backdrop(dark: false)
            HStack(spacing: 48) {
                VStack(alignment: .leading, spacing: 20) {
                    if let icon = NSApplication.shared.applicationIconImage {
                        Image(nsImage: icon).resizable().frame(width: 136, height: 136).padding(.leading, -12)
                    }
                    Text("Claude Switch").font(.system(size: 66, weight: .bold, design: .rounded)).foregroundStyle(Color(hex: 0x2A1A14))
                    Text("Every Claude Desktop account,\none click away in your menu bar.")
                        .font(.system(size: 28, weight: .medium)).foregroundStyle(Color(hex: 0x5B463D)).lineSpacing(4)
                    Text("Free & open source · macOS 14+").font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.brand)
                }
                Spacer(minLength: 0)
                Image(nsImage: menu).resizable().aspectRatio(contentMode: .fit).frame(height: 548)
                    .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
            }
            .padding(.horizontal, 72)
        }
        .environment(\.colorScheme, .light)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
