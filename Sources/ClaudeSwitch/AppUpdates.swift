import Foundation
import Observation
import SwitchCore
import SwitchMac
import SwitchStorage

@MainActor
@Observable
final class AppUpdates {
    enum Status: Equatable { case idle, checking, current, available, failed, cooldown, unknownVersion }
    let currentVersion: String
    private(set) var latestVersion: ReleaseVersion?
    private(set) var status = Status.idle
    private(set) var automatic: Bool
    var isChecking: Bool { status == .checking }
    var hasUpdate: Bool {
        guard let current = ReleaseVersion(currentVersion), let latestVersion else { return false }
        return latestVersion > current
    }
    @ObservationIgnored private let demo: Bool
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let fetch: () async throws -> ReleaseVersion
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var retryAfter: Date?

    init(demo: Bool, currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—",
         defaults: UserDefaults? = nil, now: @escaping () -> Date = Date.init,
         fetch: (() async throws -> ReleaseVersion)? = nil) {
        self.demo = demo; self.currentVersion = currentVersion; self.now = now
        let storage = demo ? nil : (defaults ?? .standard)
        self.defaults = storage
        automatic = storage?.object(forKey: "updates.automatic") as? Bool ?? true
        lastAttempt = storage?.object(forKey: "updates.releasePage.lastAttempt") as? Date
        retryAfter = storage?.object(forKey: "updates.releasePage.retryAfter") as? Date
        latestVersion = storage?.string(forKey: "updates.latestVersion").flatMap(ReleaseVersion.init)
        self.fetch = fetch ?? { try await GitHubReleaseClient(endpoint: ProjectLink.releases).fetch() }
        if hasUpdate { status = .available }
        else if latestVersion != nil, let success = storage?.object(forKey: "updates.releasePage.lastSuccess") as? Date,
                success == lastAttempt, (0..<86400).contains(now().timeIntervalSince(success)) {
            status = ReleaseVersion(currentVersion) == nil ? .unknownVersion : .current
        }
    }
    func start() {
        guard !demo, timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check(manual: false)
                do { try await Task.sleep(for: .seconds(3600)) } catch { return }
                guard self != nil else { return }
            }
        }
    }
    func setAutomatic(_ value: Bool) {
        automatic = value; defaults?.set(value, forKey: "updates.automatic")
        if value, timer != nil { Task { await check(manual: false) } }
    }
    func check(manual: Bool) async {
        guard !demo, !isChecking, manual || automatic else { return }
        let date = now()
        if let retryAfter, date < retryAfter { if manual { status = .cooldown }; return }
        if let lastAttempt {
            let elapsed = date.timeIntervalSince(lastAttempt)
            if elapsed >= 0 && elapsed < (manual ? 60 : 86400) {
                if manual, status != .current && status != .available { status = .cooldown }
                return
            }
        }
        lastAttempt = date; defaults?.set(date, forKey: "updates.releasePage.lastAttempt")
        status = .checking
        do {
            let version = try await fetch()
            latestVersion = version; defaults?.set(version.description, forKey: "updates.latestVersion")
            defaults?.set(date, forKey: "updates.releasePage.lastSuccess")
            retryAfter = nil; defaults?.removeObject(forKey: "updates.releasePage.retryAfter")
            status = ReleaseVersion(currentVersion) == nil ? .unknownVersion : hasUpdate ? .available : .current
        } catch {
            await RuntimeLog.shared.record(.failed, component: .update, level: .warning, failure: RuntimeFailure(error))
            if let date = (error as? ReleaseCheckError)?.retryAfter {
                retryAfter = date; defaults?.set(date, forKey: "updates.releasePage.retryAfter")
            }
            status = .failed
        }
    }
    var statusText: String {
        switch status {
        case .idle: return L10n.tr("Check for a newer version on GitHub.")
        case .checking: return L10n.tr("Checking for updates…")
        case .current: return L10n.tr("You're up to date.")
        case .available: return L10n.tr("Version {0} is available.", latestVersion?.description ?? "—")
        case .failed: return L10n.tr("Could not check for updates. Try again later or open the releases page.")
        case .cooldown: return L10n.tr("Please wait before checking again. You can still open the releases page.")
        case .unknownVersion: return L10n.tr("Could not compare versions. Open the releases page to check.")
        }
    }
}
