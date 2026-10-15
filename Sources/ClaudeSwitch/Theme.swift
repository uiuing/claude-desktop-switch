import SwiftUI
import SwitchCore

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    static let preferenceKey = "interfaceTheme"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L10n.tr("Follow system")
        case .light: return L10n.tr("Light")
        case .dark: return L10n.tr("Dark")
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

private struct AppThemeModifier: ViewModifier {
    @AppStorage(AppTheme.preferenceKey) private var selection = AppTheme.system.rawValue
    private var theme: AppTheme { AppTheme(rawValue: selection) ?? .system }

    func body(content: Content) -> some View {
        content.preferredColorScheme(theme.colorScheme)
            .onChange(of: selection, initial: true) { _, _ in theme.apply() }
    }
}

enum Palette {
    /// Same terracotta family as the app icon.
    static let brand = Color(red: 0.80, green: 0.45, blue: 0.33)
    static let green = Color(nsColor: .systemGreen)
    static let line = Color.primary.opacity(0.08)
    static func quota(_ remaining: Double?) -> Color {
        guard let remaining else { return .secondary }
        if remaining <= 10 { return Color(nsColor: .systemRed) }
        if remaining <= 25 { return Color(nsColor: .systemOrange) }
        return brand
    }
}

/// Claude's own menu bar icon for the status item, in front of the percentage only; everywhere else the app
/// uses its own icon. Read from the installed Claude app at runtime so no Anthropic artwork ships with
/// Claude Switch. Without Claude installed, the app's own switch glyph stands in.
@MainActor
enum StatusIcon {
    static let image: NSImage = {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop"),
           let icon = Bundle(url: app)?.image(forResource: "TrayIconTemplate") {
            icon.isTemplate = true
            return icon
        }
        return MenuBarMark.image
    }()
}

/// The app icon's switch as a template image, so the status bar tints it like system icons.
/// Drawn on a 26 × 16 grid: a capsule track, a ring for the other account and a knob for the active one.
@MainActor
enum MenuBarMark {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 13.5), flipped: false) { rect in
            let unit = rect.height / 16
            NSColor.black.set()
            let track = NSBezierPath(roundedRect: NSRect(x: unit, y: unit, width: 24 * unit, height: 14 * unit),
                                     xRadius: 7 * unit, yRadius: 7 * unit)
            track.lineWidth = 1.7 * unit
            track.stroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: 5.7 * unit, y: 5.7 * unit, width: 4.6 * unit, height: 4.6 * unit))
            ring.lineWidth = 1.5 * unit
            ring.stroke()
            NSBezierPath(ovalIn: NSRect(x: 13.7 * unit, y: 3.7 * unit, width: 8.6 * unit, height: 8.6 * unit)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

struct KindIcon: View {
    let kind: SessionKind
    var size: CGFloat = 28
    private var symbol: String {
        switch kind { case .code: return "chevron.left.forwardslash.chevron.right"; case .cowork: return "folder"; case .chat: return "bubble.left" }
    }
    private var tint: Color {
        switch kind { case .code: return Color(nsColor: .systemBlue); case .cowork: return Color(nsColor: .systemPurple); case .chat: return Palette.brand }
    }
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tint.opacity(0.14))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(tint))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    let text: String
    var color: Color = Palette.green
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .foregroundStyle(color).background(color.opacity(0.13), in: Capsule())
    }
}

private struct CardSurface: ViewModifier {
    var highlighted: Bool
    var radius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.055) : Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.05), radius: 3, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(
                    highlighted ? Palette.brand.opacity(0.75) : Color.primary.opacity(contrast == .increased ? 0.3 : 0.07),
                    lineWidth: highlighted ? 1.5 : 1)
            }
    }
}

extension View {
    func appTheme() -> some View { modifier(AppThemeModifier()) }
    func card(highlighted: Bool = false, radius: CGFloat = 12) -> some View {
        modifier(CardSurface(highlighted: highlighted, radius: radius))
    }
    /// Rounded hover highlight behind controls whose own style has none, such as borderless menus.
    func hoverSurface(radius: CGFloat = 6) -> some View {
        modifier(HoverSurface(radius: radius))
    }
    /// Hover tip. SwiftUI's `help` does not show in every hierarchy, so an AppKit tooltip sits behind it too.
    func hint(_ text: String?) -> some View {
        help(text ?? "").background(ToolTipHost(text: text))
    }
}

/// Redraws its content every second while `running`, for countdowns; otherwise only when its inputs change.
struct SecondsTimeline<Content: View>: View {
    let running: Bool
    @ViewBuilder let content: () -> Content
    var body: some View {
        if running { TimelineView(.periodic(from: .now, by: 1)) { _ in content() } } else { content() }
    }
}

private struct HoverSurface: ViewModifier {
    let radius: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.primary.opacity(hovering && enabled ? 0.08 : 0)))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Clickable card: tints over the card surface on hover and press, since a background behind it would be hidden.
struct CardButtonStyle: ButtonStyle {
    var radius: CGFloat = 12
    func makeBody(configuration: Configuration) -> some View { CardButton(configuration: configuration, radius: radius) }
    private struct CardButton: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : hovering && enabled ? 0.04 : 0))
                    .allowsHitTesting(false))
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

private struct ToolTipHost: NSViewRepresentable {
    let text: String?
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); view.toolTip = text
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { view.toolTip = text }
}

struct QuotaBar: View {
    let row: QuotaReadout
    var height: CGFloat = 6
    /// Remaining percentage an even pace would leave now, drawn as a tick across the bar.
    var marker: Double? = nil
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let overhang: CGFloat = marker == nil ? 0 : 2
        Canvas { context, size in
            let rect = CGRect(x: 0, y: overhang, width: size.width, height: size.height - overhang * 2)
            let radius = rect.height / 2
            let track = row.remainingPercent == nil ? 0.045 : contrast == .increased ? 0.22 : 0.09
            context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(.primary.opacity(track)))
            if let remaining = row.remainingPercent, remaining > 0 {
                let width = max(rect.height, rect.width * min(100, remaining) / 100)
                context.fill(Path(roundedRect: CGRect(x: 0, y: rect.minY, width: width, height: rect.height), cornerRadius: radius),
                             with: .color(Palette.quota(remaining)))
            }
            if let marker {
                let x = min(max(0, size.width * min(100, max(0, marker)) / 100 - 1), size.width - 2)
                context.fill(Path(roundedRect: CGRect(x: x, y: 0, width: 2, height: size.height), cornerRadius: 1),
                             with: .color(.primary.opacity(0.65)))
            }
        }.frame(height: height + overhang * 2).accessibilityHidden(true)
    }
}

/// Full-size quota readout used on account cards.
struct QuotaGauge: View {
    @AppStorage(Format.showResetTimeKey) private var showResetTime = true
    let row: QuotaReadout
    var now = Date()
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(row.percentageText).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(row.remainingPercent.map { $0 <= 10 ? Palette.quota($0) : .primary } ?? .secondary)
            }
            QuotaBar(row: row)
            Text(Format.reset(row, now: now, showResetTime: showResetTime)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .hint(Format.resetDetail(row))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Format.quotaAccessibility(row, now: now, showResetTime: showResetTime))
    }
}

/// Single-line quota readout used in the menu bar panel.
struct QuotaLine: View {
    @AppStorage(Format.showResetTimeKey) private var showResetTime = true
    let row: QuotaReadout
    var now = Date()
    var body: some View {
        HStack(spacing: 8) {
            Text(row.title).frame(minWidth: 48, alignment: .leading).foregroundStyle(.secondary)
            QuotaBar(row: row, height: 4)
            Text(row.percentageText).monospacedDigit().frame(width: 34, alignment: .trailing)
                .foregroundStyle(row.remainingPercent.map { $0 <= 10 ? Palette.quota($0) : .primary } ?? .secondary)
            Text(Format.shortReset(row, now: now, showResetTime: showResetTime)).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 62, alignment: .trailing)
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Format.quotaAccessibility(row, now: now, showResetTime: showResetTime))
    }
}

enum Format {
    static let showResetTimeKey = "showResetTime"
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000_000 { return String(format: "%.2fB", locale: L10n.locale, Double(count) / 1_000_000_000) }
        if count >= 1_000_000 { return String(format: "%.2fM", locale: L10n.locale, Double(count) / 1_000_000) }
        if count >= 1000 { return String(format: "%.1fK", locale: L10n.locale, Double(count) / 1000) }
        return L10n.number(count)
    }
    /// `claude-sonnet-4-5-20250929` → `Sonnet 4.5`, `claude-3-5-haiku` → `3.5 Haiku`.
    static func model(_ raw: String) -> String {
        var parts = raw.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init)
        if parts.count > 1, let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        var words: [String] = []
        for part in parts {
            if part.allSatisfy(\.isNumber), let previous = words.last, previous.allSatisfy({ $0.isNumber || $0 == "." }) {
                words[words.count - 1] = previous + "." + part
            } else {
                words.append(part.allSatisfy(\.isNumber) ? part : part.capitalized)
            }
        }
        return words.isEmpty ? raw : words.joined(separator: " ")
    }
    static func age(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.locale(L10n.locale).year().month(.abbreviated).day().hour().minute())
    }
    private static func duration(_ minutes: Int, short: Bool) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = L10n.locale
        formatter.calendar = calendar
        formatter.allowedUnits = minutes >= 1440 ? [.day, .hour] : [.hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = short ? .abbreviated : .full
        return formatter.string(from: TimeInterval(minutes * 60)) ?? L10n.number(minutes)
    }
    static func quotaAccessibility(_ row: QuotaReadout, now: Date, showResetTime: Bool = true) -> String {
        let quota = row.remainingPercent == nil ? L10n.tr("Quota unknown") : L10n.tr("{0} remaining", row.percentageText)
        return [row.title, quota, reset(row, now: now, showResetTime: showResetTime)].joined(separator: ", ")
    }
    private static func remaining(_ row: QuotaReadout, now: Date) -> Int? {
        guard let reset = row.resetsAt else { return nil }
        let seconds = reset.timeIntervalSince(now)
        guard seconds.isFinite, seconds > 0, seconds <= 366 * 86400 else { return nil }
        return max(1, Int(ceil(seconds / 60)))
    }
    static func reset(_ row: QuotaReadout, now: Date, showResetTime: Bool = true) -> String {
        if row.state == .unknown { return L10n.tr("No data yet") }
        if row.state == .resetPending { return L10n.tr("Awaiting confirmation") }
        if row.state == .stale { return L10n.tr("Last reading · {0}", row.observedAt.map { age($0, now: now) } ?? "—") }
        if row.awaitingFirstUse { return L10n.tr("Starts on next use") }
        guard let minutes = remaining(row, now: now) else { return L10n.tr("Reset time unknown") }
        if showResetTime, let reset = row.resetsAt {
            let moment = resetMoment(reset)
            return row.resetIsEstimate ? L10n.tr("Resets by {0}", moment) : L10n.tr("Resets at {0}", moment)
        }
        return row.resetIsEstimate
            ? L10n.tr("Resets in about {0}", duration(minutes, short: false))
            : L10n.tr("Resets in {0}", duration(minutes, short: false))
    }
    /// Full reset date, including the estimate qualifier, or why there is none.
    static func resetDetail(_ row: QuotaReadout) -> String? {
        guard row.state != .unknown else { return nil }
        if row.state == .resetPending { return L10n.tr("The expected reset time has passed. Refresh to confirm the current quota.") }
        let source = row.observedAt.map { L10n.tr("{0} · Updated {1}", row.origin.title, date($0)) }
        if row.awaitingFirstUse { return L10n.tr("This session hasn't started yet; it starts with your next message.") }
        guard let reset = row.resetsAt else { return L10n.tr("Local records have no reset time; refresh to read it from the live quota.") }
        let detail = row.resetIsEstimate ? L10n.tr("Resets by {0} at the latest (estimate)", date(reset)) : L10n.tr("quota.resetTooltip {0}", date(reset))
        return [source, detail].compactMap { $0 }.joined(separator: " · ")
    }
    /// Show a time today, a localized tomorrow label, or a localized date and time.
    private static func resetMoment(_ date: Date) -> String {
        let time = date.formatted(.dateTime.locale(L10n.locale).hour().minute())
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInTomorrow(date) { return L10n.tr("Tomorrow {0}", time) }
        return date.formatted(.dateTime.locale(L10n.locale).month(.abbreviated).day().weekday(.abbreviated).hour().minute())
    }
    /// Like `reset`, but falls back to a duration when the moment is past tomorrow, so it fits a narrow column.
    static func compactReset(_ row: QuotaReadout, now: Date, showResetTime: Bool = true) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let near = row.resetsAt.map { calendar.isDateInToday($0) || calendar.isDateInTomorrow($0) } ?? false
        return reset(row, now: now, showResetTime: showResetTime && near)
    }
    /// The shortest reset label, for a table column: the time if today, else how long until it.
    /// A "tomorrow" label with a time does not fit the column in every language.
    static func tinyReset(_ row: QuotaReadout, now: Date, showResetTime: Bool = true) -> String {
        if row.state == .resetPending { return L10n.tr("quota.pending") }
        if row.state == .stale { return L10n.tr("quota.stale") }
        if row.awaitingFirstUse { return L10n.tr("Not started") }
        guard row.state != .unknown, let minutes = remaining(row, now: now), let reset = row.resetsAt else { return "—" }
        if showResetTime, Calendar.autoupdatingCurrent.isDateInToday(reset) { return resetMoment(reset) }
        if minutes < 60 { return L10n.tr("in {0}m", L10n.number(minutes)) }
        if minutes < 1440 { return L10n.tr("in {0}h", L10n.number((minutes + 59) / 60)) }
        return L10n.tr("in {0}d", L10n.number((minutes + 1439) / 1440))
    }
    static func shortReset(_ row: QuotaReadout, now: Date, showResetTime: Bool = true) -> String {
        if row.state == .resetPending { return L10n.tr("quota.pending") }
        if row.state == .stale { return L10n.tr("quota.stale") }
        guard row.state != .unknown, let minutes = remaining(row, now: now) else { return "—" }
        let value = showResetTime ? row.resetsAt.map(resetMoment) ?? duration(minutes, short: true) : duration(minutes, short: true)
        return row.resetIsEstimate ? L10n.tr("By {0}", value) : value
    }
}
