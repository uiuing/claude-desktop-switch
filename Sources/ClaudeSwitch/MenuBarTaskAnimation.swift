import AppKit
import Foundation
import Observation

/// Only the status label observes these frames; task rows and account views do not redraw with it.
@MainActor @Observable
final class MenuBarTaskAnimation {
    static let frameCount = 90
    private static let framesPerSecond = 60.0
    private(set) var frame = 0
    private(set) var isAnimating = false
    @ObservationIgnored private let enabled: Bool
    @ObservationIgnored private let reduceMotion: () -> Bool
    @ObservationIgnored private var requested = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var displayObserver: NSObjectProtocol?
    @ObservationIgnored private var notificationCenter: NotificationCenter?

    init(enabled: Bool = true, observeSystem: Bool = true, reduceMotion: (() -> Bool)? = nil) {
        self.enabled = enabled
        self.reduceMotion = reduceMotion ?? { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        if enabled && observeSystem {
            let center = NSWorkspace.shared.notificationCenter
            notificationCenter = center
            displayObserver = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.reconcile() }
                }
        }
    }
    deinit {
        ticker?.cancel()
        if let displayObserver { notificationCenter?.removeObserver(displayObserver) }
    }
    func setRunning(_ running: Bool) {
        requested = running
        reconcile()
    }
    func reconcile() {
        let animate = enabled && requested && !reduceMotion()
        guard animate != isAnimating else { return }
        ticker?.cancel(); ticker = nil
        isAnimating = animate; frame = 0
        guard animate else { return }
        ticker = Task { [weak self] in
            let began = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 16_666_667) } catch { return }
                guard !Task.isCancelled, let self, self.isAnimating else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                self.frame = Int(elapsed * Self.framesPerSecond) % Self.frameCount
            }
        }
    }
}
