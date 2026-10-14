import Foundation
import SwitchCore

/// Sample data for `--demo`: fictional, never read from or written to disk. The signed-in account is nearly
/// out of session quota, so the menu bar suggests a switch, as it would in daily use.
enum DemoData {
    struct Content {
        var library: LibraryState
        var inventory: LocalInventory
        var analytics: UsageAnalytics
    }

    static func make(now: Date = Date()) -> Content {
        func account(_ id: String, _ organization: String, _ email: String, plan: String) -> Account {
            var account = Account(id: id, email: email, organizationID: organization, hasSnapshot: true, lastSavedAt: now)
            account.observePlan(plan, organizationID: organization, at: now)
            return account
        }
        // Addresses are stored already masked, so no complete address exists even in the sample data.
        let personal = account("11111111-1111-4111-8111-111111111111", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "mi•••el@gmail.com", plan: "Max 20x")
        let studio = account("22222222-2222-4222-8222-222222222222", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "je•••er@outlook.com", plan: "Max 5x")
        let team = account("33333333-3333-4333-8333-333333333333", "cccccccc-cccc-4ccc-8ccc-cccccccccccc", "da•••id@icloud.com", plan: "Team")
        let research = account("44444444-4444-4444-8444-444444444444", "dddddddd-dddd-4ddd-8ddd-dddddddddddd", "so•••ia@yahoo.com", plan: "Pro")

        func window(_ id: String, left: Double, resetsIn seconds: TimeInterval?) -> QuotaWindow {
            .init(id: id, title: L10n.quotaTitle(id, fallback: id), usedPercent: 100 - left,
                  resetsAt: seconds.map { now.addingTimeInterval($0) })
        }
        let usage: [UsageSnapshot] = [
            UsageSnapshot(accountID: personal.id, observedAt: now.addingTimeInterval(-120), origin: .live,
                          windows: [window("five_hour", left: 14, resetsIn: 6_700), window("seven_day", left: 58, resetsIn: 262_000),
                                    window("seven_day_opus", left: 71, resetsIn: 262_000)]),
            UsageSnapshot(accountID: studio.id, observedAt: now.addingTimeInterval(-2_400), origin: .localCache,
                          windows: [window("five_hour", left: 92, resetsIn: 15_100), window("seven_day", left: 83, resetsIn: 431_000)]),
            UsageSnapshot(accountID: team.id, observedAt: now.addingTimeInterval(-5_400), origin: .localCache,
                          windows: [window("five_hour", left: 67, resetsIn: 9_800), window("seven_day", left: 41, resetsIn: 128_000)]),
            UsageSnapshot(accountID: research.id, observedAt: now.addingTimeInterval(-10_800), origin: .localCache,
                          windows: [window("five_hour", left: 100, resetsIn: nil), window("seven_day", left: 12, resetsIn: 64_000)]),
        ]

        let sessions: [(title: String, account: Account, kind: SessionKind, model: String, project: String)] = [
            (L10n.tr("demo.menuBarQuota"), personal, .code, "claude-opus", "~/Developer/menubar-app"),
            (L10n.tr("demo.designNavigation"), personal, .code, "claude-opus", "~/Developer/menubar-app"),
            (L10n.tr("demo.copyConflicts"), personal, .code, "claude-sonnet", "~/Developer/menubar-app"),
            (L10n.tr("demo.apiMigration"), team, .code, "claude-opus", "~/Developer/billing-service"),
            (L10n.tr("demo.flakyTests"), team, .code, "claude-sonnet", "~/Developer/billing-service"),
            (L10n.tr("demo.homepage"), studio, .code, "claude-sonnet", "~/Developer/landing-page"),
            (L10n.tr("demo.onboardingFlow"), studio, .code, "claude-haiku", "~/Developer/landing-page"),
            (L10n.tr("demo.researchNotes"), research, .cowork, "claude-opus", "~/Documents/research"),
        ]
        let conversations = sessions.enumerated().map { index, item in
            Conversation(id: "demo-\(index)", sessionID: "demo-session-\(index)", accountID: item.account.id,
                         organizationID: item.account.organizationID!, title: item.title, kind: item.kind,
                         modifiedAt: now.addingTimeInterval(-Double(index * index * 2400 + index * 1500 + 120)),
                         model: item.model, project: item.project, recordRelativePath: "demo", cliSessionID: "demo-cli-\(index)")
        }

        var library = LibraryState()
        library.preferences.maskEmail = true
        library.accounts = [personal, studio, team, research]
        library.usage = Dictionary(uniqueKeysWithValues: usage.map { ($0.accountID, $0) })
        library.follows = [FollowRule(conversationID: conversations[1].id, sessionID: conversations[1].sessionID),
                           FollowRule(conversationID: conversations[2].id, sessionID: conversations[2].sessionID)]
        let inventory = LocalInventory(activeAccountID: personal.id, accounts: library.accounts, conversations: conversations,
                                       usage: usage[0], warnings: [L10n.tr("demo.sampleNotice")], signedIn: true)
        return Content(library: library, inventory: inventory, analytics: analytics(now: now))
    }

    /// Almost a year of steadily growing activity from a fixed seed, so every launch and screenshot looks the same.
    private static func analytics(now: Date) -> UsageAnalytics {
        var random = SeededRandom(seed: 0x5EED_C1A0DE)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let span = 330
        var days: [ActivityDay] = []
        for offset in stride(from: span, through: 0, by: -1) {
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            let growth = 1 - Double(offset) / Double(span)
            let weekend = calendar.isDateInWeekend(date)
            let chance = (weekend ? 0.3 : 0.62) + growth * (weekend ? 0.3 : 0.36)
            guard offset < 23 || random.next() < chance else { continue }
            var day = ActivityDay(date: date)
            let intensity = (0.35 + growth * 0.9) * (weekend ? 0.55 : 1) * (0.6 + random.next() * 0.8)
            day.sessions = max(1, Int(2 + intensity * 6))
            day.messages = max(12, Int(intensity * 420))
            for _ in 0..<day.sessions {
                let hour = random.next() < 0.55 ? 9 + Int(random.next() * 4) : 14 + Int(random.next() * 8)
                day.hours[hour, default: 0] += 1
            }
            let mix: [(String, Double)] = offset > 200
                ? [("claude-opus", 0.3), ("claude-sonnet", 0.6), ("claude-haiku", 0.10)]
                : offset > 90
                    ? [("claude-opus", 0.45), ("claude-sonnet", 0.45), ("claude-haiku", 0.10)]
                    : [("claude-opus", 0.58), ("claude-sonnet", 0.32), ("claude-haiku", 0.10)]
            for (name, share) in mix {
                let messages = max(1, Int(Double(day.messages) * share * (0.7 + random.next() * 0.6)))
                var model = ActivityModel(model: name)
                model.messages = messages
                let scale = Double(messages) * (0.8 + random.next() * 0.4)
                model.counts = TokenCounts(input: Int(scale * 420), output: Int(scale * 1_350),
                                           cacheRead: Int(scale * 58_000), cacheWrite: Int(scale * 4_200))
                day.models[name] = model
            }
            days.append(day)
        }
        var analytics = UsageAnalytics()
        analytics.days = days
        analytics.scannedFiles = 412; analytics.totalFiles = 412
        return analytics
    }
}

/// SplitMix64, enough for stable sample data.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
