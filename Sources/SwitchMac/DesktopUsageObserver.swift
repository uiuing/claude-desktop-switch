import AppKit
import Foundation
import Network
import SwitchStorage
import SwitchCore

/// Watches publication, not decrypted credentials. Polling in AppState remains the fallback.
public final class DesktopUsageObserver: @unchecked Sendable {
    public enum Event: Sendable { case credentials, wake, sleep, networkRestored, networkUnavailable, launched, terminated }
    public static let bundleID = "com.anthropic.claudefordesktop"
    @MainActor public static func activity(online: Bool, awake: Bool) -> QuotaRefreshSchedule.Activity {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
        return .init(running: running, online: online, awake: awake)
    }
    private let directory: URL
    private let receive: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "dev.claudeswitch.credential-observer")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounce: DispatchWorkItem?
    private let network = NWPathMonitor()
    private var notifications: [NSObjectProtocol] = []
    public init(directory: URL, receive: @escaping @Sendable (Event) -> Void) {
        self.directory = directory; self.receive = receive
        queue.async { [weak self] in self?.watch() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in receive(.wake) })
        }
        notifications.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in receive(.sleep) })
        for (name, event) in [(NSWorkspace.didLaunchApplicationNotification, Event.launched),
                              (NSWorkspace.didTerminateApplicationNotification, .terminated)] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == Self.bundleID else { return }
                receive(event)
            })
        }
        network.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.receive(path.status == .satisfied ? .networkRestored : .networkUnavailable)
        }
        network.start(queue: queue)
    }
    deinit {
        debounce?.cancel(); sources.forEach { $0.cancel() }; network.cancel()
        for observer in notifications { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    private func watch() {
        sources.forEach { $0.cancel() }; sources.removeAll()
        for url in [directory, directory.appendingPathComponent("config.json"), directory.appendingPathComponent("config.json.journal")] {
            guard (try? SafeFiles.validateAncestors(url)) != nil else { continue }
            let fd = open(url.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: queue)
            source.setCancelHandler { close(fd) }
            source.setEventHandler { [weak self] in
                guard let self else { return }
                debounce?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    self?.receive(.credentials)
                    self?.watch()
                }
                debounce = item; queue.asyncAfter(deadline: .now() + 0.5, execute: item)
            }
            sources.append(source); source.resume()
        }
    }
}
