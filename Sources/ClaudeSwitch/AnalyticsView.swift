import SwiftUI
import Charts
import SwitchCore

struct AnalyticsView: View {
    @EnvironmentObject var state: AppState
    private var report: UsageAnalytics { state.analytics.filtered(days: state.tokenDays) }
    var body: some View {
        Group {
            if !state.tokenScanDone {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.tr("Scanning local records for the first time…")).font(.headline)
                    Text(L10n.tr("Building a statistics cache for faster loading next time. You can use other pages while the scan continues."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content(report)
            }
        }
        .navigationTitle(L10n.tr("Usage"))
        .navigationSubtitle(L10n.tr("Local Claude Code"))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(L10n.tr("Range"), selection: $state.tokenDays) {
                    Text(L10n.tr("All")).tag(0); Text(L10n.tr("Today")).tag(1); Text(L10n.tr("7 days")).tag(7); Text(L10n.tr("30 days")).tag(30)
                }.pickerStyle(.segmented).fixedSize()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await state.scanTokens() } } label: {
                    Label(L10n.tr("Refresh"), systemImage: "arrow.clockwise")
                }.disabled(state.scanningTokens).help(L10n.tr("Recalculate"))
            }
        }
        .onAppear { if !state.tokenScanDone { Task { await state.scanTokens() } } }
    }
    private func content(_ report: UsageAnalytics) -> some View {
        ScrollView { cards(report) }
    }
    private func cards(_ report: UsageAnalytics) -> some View {
        let span = RangeSpan(range: state.tokenDays, report: report)
        let palette = ModelPalette(report.models)
        return VStack(alignment: .leading, spacing: 16) {
                scanStatus
                OverviewCard(report: report, span: span, showsStreaks: state.tokenDays != 1)
                if state.tokenDays == 1 {
                    if report.sessions > 0 { HoursCard(report: report) }
                } else {
                    ActivityHeatmap(days: state.analytics.days, rangeStart: state.tokenDays == 0 ? nil : span.start)
                    DailyTokensCard(report: report, span: span, palette: palette)
                }
                ModelsCard(report: report, palette: palette)
                footnote
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
            .frame(maxWidth: 1040).frame(maxWidth: .infinity)
    }
    @ViewBuilder private var scanStatus: some View {
        if state.scanningTokens {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.tr(state.tokenInitialScan ? "Scanning local records for the first time…" : "Updating statistics in the background…"))
                    Spacer()
                    Text(L10n.tr("Scanned {0}/{1} files", L10n.argument(state.analytics.scannedFiles), L10n.argument(state.analytics.totalFiles)))
                        .monospacedDigit()
                }.font(.system(size: 12)).foregroundStyle(.secondary)
                ProgressView(value: min(1, Double(state.analytics.processedBytes) / Double(max(1, state.analytics.totalBytes))))
                    .controlSize(.small)
                if state.tokenInitialScan {
                    Text(L10n.tr("Building a statistics cache for faster loading next time. You can use other pages while the scan continues."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.vertical, 12).card(radius: 10)
        } else if let error = state.tokenScanError {
            Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
        } else if state.analytics.partial {
            Label(L10n.tr("Some records are unavailable; retrying automatically"), systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(.orange)
        }
    }
    private var footnote: some View {
        var parts = [L10n.tr("Matches Claude’s local activity statistics, including cached tokens; not subscription limits or charges")]
        if state.analytics.cacheWriteFailed { parts.append(L10n.tr("Could not save the statistics cache; the next launch will rescan")) }
        return Text(parts.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center).padding(.top, 4)
    }
}

/// The calendar days a range covers; All runs from the first recorded day to today.
private struct RangeSpan {
    let start: Date
    let dates: [Date]
    init(range: Int, report: UsageAnalytics, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let first = range > 0
            ? calendar.date(byAdding: .day, value: -(range - 1), to: today)!
            : min(today, report.days.first.map { calendar.startOfDay(for: $0.date) } ?? today)
        let count = (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1
        start = first
        dates = (0..<max(1, count)).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }
}

private extension UsageAnalytics {
    /// Same rule as Claude Desktop: the current streak counts back from today, so an idle today means zero.
    func streaks(now: Date = Date(), calendar: Calendar = .current) -> (current: Int, longest: Int) {
        let active = Set(days.filter { $0.messages > 0 }.map { calendar.startOfDay(for: $0.date) })
        guard !active.isEmpty else { return (0, 0) }
        var current = 0, day = calendar.startOfDay(for: now)
        while active.contains(day) { current += 1; day = calendar.date(byAdding: .day, value: -1, to: day)! }
        let sorted = active.sorted()
        var longest = 1, run = 1
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            run = calendar.dateComponents([.day], from: previous, to: next).day == 1 ? run + 1 : 1
            longest = max(longest, run)
        }
        return (current, longest)
    }
    var hourTotals: [Int] {
        (0..<24).map { hour in days.reduce(0) { $0 + ($1.hours[hour] ?? 0) } }
    }
}

private func hourText(_ hour: Int?) -> String {
    guard let hour, let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) else { return "—" }
    return date.formatted(.dateTime.hour().locale(L10n.locale))
}

// MARK: - Colors

private enum TokenKind: CaseIterable, Identifiable {
    case input, output, cacheRead, cacheWrite
    var id: Self { self }
    var title: String {
        switch self {
        case .input: return L10n.tr("Input")
        case .output: return L10n.tr("Output")
        case .cacheRead: return L10n.tr("Cache read")
        case .cacheWrite: return L10n.tr("Cache write")
        }
    }
    var color: Color {
        switch self {
        case .input: return Palette.brand
        case .output: return Color(red: 0.52, green: 0.27, blue: 0.19)
        case .cacheRead: return Color(red: 0.90, green: 0.73, blue: 0.59)
        case .cacheWrite: return Color(red: 0.68, green: 0.63, blue: 0.58)
        }
    }
    func value(_ counts: TokenCounts) -> Int {
        switch self {
        case .input: return counts.input
        case .output: return counts.output
        case .cacheRead: return counts.cacheRead
        case .cacheWrite: return counts.cacheWrite
        }
    }
}

/// The four largest models get their own color; the rest share one series so the chart stays readable.
private struct ModelPalette {
    static let otherID = "\u{0}other"
    private static let colors: [Color] = [
        Palette.brand, Color(red: 0.38, green: 0.52, blue: 0.70),
        Color(red: 0.47, green: 0.62, blue: 0.45), Color(red: 0.62, green: 0.49, blue: 0.68),
    ]
    private static let otherColor = Color(nsColor: .systemGray)
    let top: [String]
    let hasOther: Bool
    init(_ models: [ActivityModel]) {
        top = models.prefix(Self.colors.count).map(\.model)
        hasOther = models.count > Self.colors.count
    }
    func series(_ model: String) -> String { top.contains(model) ? model : Self.otherID }
    func color(_ model: String) -> Color { top.firstIndex(of: model).map { Self.colors[$0] } ?? Self.otherColor }
    func title(_ series: String) -> String { series == Self.otherID ? L10n.tr("Other") : Format.model(series) }
    var domain: [String] { top + (hasOther ? [Self.otherID] : []) }
    var range: [Color] { domain.map(color) }
}

// MARK: - Overview

private struct OverviewCard: View {
    let report: UsageAnalytics
    let span: RangeSpan
    let showsStreaks: Bool
    var body: some View {
        let totals = report.totals
        let streaks = report.streaks()
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("Total tokens")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text(Format.tokens(totals.total)).font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText()).lineLimit(1)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(L10n.tr("Favorite model")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text(report.models.first.map { Format.model($0.model) } ?? "—")
                        .font(.system(size: 17, weight: .semibold)).lineLimit(1)
                }
            }
            CompositionBar(counts: totals)
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 16, alignment: .leading)],
                      alignment: .leading, spacing: 16) {
                Metric(title: L10n.tr("Sessions"), value: L10n.number(report.sessions))
                Metric(title: L10n.tr("analytics.messageCount"), value: L10n.number(report.messages))
                if showsStreaks {
                    Metric(title: L10n.tr("Active days"), value: L10n.number(report.activeDays),
                           detail: "/ " + L10n.number(span.dates.count))
                    Metric(title: L10n.tr("Current streak"), value: L10n.tr("{0} days", L10n.argument(streaks.current)))
                    Metric(title: L10n.tr("Longest streak"), value: L10n.tr("{0} days", L10n.argument(streaks.longest)))
                }
                Metric(title: L10n.tr("Peak hour"), value: hourText(report.peakHour))
            }
            if report.sessions == 0 && report.messages > 0 {
                Label(L10n.tr("Messages in this period come from sessions that started earlier. Sessions and peak hour count by session start time, as in Claude Desktop."),
                      systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(20).card()
    }
}

private struct Metric: View {
    let title: String, value: String
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.tertiary).monospacedDigit() }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CompositionBar: View {
    let counts: TokenCounts
    var body: some View {
        let total = counts.total
        VStack(alignment: .leading, spacing: 12) {
            Canvas { context, size in
                let parts = TokenKind.allCases.map { ($0, $0.value(counts)) }.filter { $0.1 > 0 }
                let gap: CGFloat = 2
                context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2))
                guard total > 0 else {
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.07)))
                    return
                }
                let usable = size.width - gap * CGFloat(parts.count - 1)
                var x: CGFloat = 0
                for (kind, value) in parts {
                    let width = max(2, usable * CGFloat(value) / CGFloat(total))
                    context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(kind.color))
                    x += width + gap
                }
            }
            .frame(height: 10).accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(TokenKind.allCases) { kind in
                    let value = kind.value(counts)
                    HStack(spacing: 6) {
                        Circle().fill(kind.color).frame(width: 7, height: 7)
                        Text(kind.title).foregroundStyle(.secondary)
                        Text(Format.tokens(value)).fontWeight(.medium)
                        if total > 0 {
                            Text((Double(value) / Double(total)).formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.system(size: 11)).monospacedDigit().lineLimit(1)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - Activity heatmap

private struct ActivityHeatmap: View {
    let days: [ActivityDay]
    /// Days before this fall outside the selected range and are dimmed; nil shows everything at full strength.
    let rangeStart: Date?
    @State private var hovered: Date?
    private static let levels: [Double] = [0.3, 0.52, 0.76, 1]
    private var calendar: Calendar { .current }
    var body: some View {
        let messages = Dictionary(days.map { (calendar.startOfDay(for: $0.date), $0.messages) }, uniquingKeysWith: +)
        let peak = messages.values.max() ?? 0
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(L10n.tr("Activity")).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let hovered {
                    Text(label(hovered, messages: messages[hovered] ?? 0))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                legend
            }
            GeometryReader { proxy in
                let layout = HeatmapLayout(width: proxy.size.width, calendar: calendar)
                Canvas { context, _ in
                    draw(layout, in: &context, messages: messages, peak: peak)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = layout.date(at: point)
                    case .ended: hovered = nil
                    }
                }
            }
            .frame(height: HeatmapLayout.height)
            .accessibilityLabel(L10n.tr("Activity"))
        }
        .padding(20).card()
    }
    private func level(_ count: Int, peak: Int) -> Int {
        guard count > 0, peak > 0 else { return 0 }
        return min(4, max(1, Int(ceil(4 * Double(count) / Double(peak)))))
    }
    private func fill(_ level: Int) -> Color {
        level == 0 ? Color.primary.opacity(0.06) : Palette.brand.opacity(Self.levels[level - 1])
    }
    private var legend: some View {
        HStack(spacing: 3) {
            Text(L10n.tr("Less")).padding(.trailing, 2)
            ForEach(0..<5) { RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(fill($0)).frame(width: 10, height: 10) }
            Text(L10n.tr("More")).padding(.leading, 2)
        }.font(.system(size: 10)).foregroundStyle(.secondary)
    }
    private func label(_ date: Date, messages: Int) -> String {
        let day = date.formatted(.dateTime.locale(L10n.locale).year().month(.abbreviated).day().weekday(.abbreviated))
        return messages > 0 ? L10n.tr("{0} · {1} messages", day, L10n.number(messages)) : L10n.tr("{0} · No activity", day)
    }
    private func draw(_ layout: HeatmapLayout, in context: inout GraphicsContext, messages: [Date: Int], peak: Int) {
        for column in 0..<layout.weeks {
            let first = layout.date(column: column, row: 0)
            if layout.startsMonth(column) {
                context.draw(Text(first.formatted(.dateTime.month(.abbreviated).locale(L10n.locale)))
                    .font(.system(size: 10)).foregroundColor(.secondary),
                             at: CGPoint(x: layout.cellRect(column: column, row: 0).minX, y: 0), anchor: .topLeading)
            }
            for row in 0..<7 {
                let date = layout.date(column: column, row: row)
                guard date <= layout.today else { continue }
                let rect = layout.cellRect(column: column, row: row)
                let shape = Path(roundedRect: rect, cornerRadius: 2.5, style: .continuous)
                var color = fill(level(messages[date] ?? 0, peak: peak))
                if let rangeStart, date < rangeStart { color = color.opacity(0.35) }
                context.fill(shape, with: .color(color))
                if date == hovered { context.stroke(shape, with: .color(.primary.opacity(0.55)), lineWidth: 1) }
            }
        }
        var localized = calendar
        localized.locale = L10n.locale
        let symbols = localized.shortWeekdaySymbols
        for row in [1, 3, 5] {
            let weekday = (calendar.firstWeekday - 1 + row) % 7
            let rect = layout.cellRect(column: 0, row: row)
            context.draw(Text(symbols[weekday]).font(.system(size: 10)).foregroundColor(.secondary),
                         at: CGPoint(x: layout.origin - 6, y: rect.midY), anchor: .trailing)
        }
    }
}

private struct HeatmapLayout {
    static let pitch: CGFloat = 14, gap: CGFloat = 3, header: CGFloat = 16, labels: CGFloat = 34
    static var height: CGFloat { header + pitch * 7 - gap }
    let weeks: Int
    let origin: CGFloat
    let today: Date
    private let lastColumnStart: Date
    private let calendar: Calendar
    init(width: CGFloat, calendar: Calendar, now: Date = Date()) {
        self.calendar = calendar
        weeks = max(1, min(53, Int((width - Self.labels + Self.gap) / Self.pitch)))
        origin = Self.labels + max(0, (width - Self.labels - CGFloat(weeks) * Self.pitch + Self.gap) / 2)
        today = calendar.startOfDay(for: now)
        let row = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
        lastColumnStart = calendar.date(byAdding: .day, value: -row, to: today)!
    }
    func date(column: Int, row: Int) -> Date {
        calendar.date(byAdding: .day, value: (column - (weeks - 1)) * 7 + row, to: lastColumnStart)!
    }
    func cellRect(column: Int, row: Int) -> CGRect {
        let size = Self.pitch - Self.gap
        return CGRect(x: origin + CGFloat(column) * Self.pitch, y: Self.header + CGFloat(row) * Self.pitch, width: size, height: size)
    }
    /// Month labels go where a month begins, leaving room for the label before the next one.
    func startsMonth(_ column: Int) -> Bool {
        let month = { calendar.component(.month, from: date(column: $0, row: 0)) }
        guard column <= weeks - 3 else { return false }
        if column == 0 { return month(0) == month(min(weeks - 1, 2)) }
        return month(column) != month(column - 1)
    }
    func date(at point: CGPoint) -> Date? {
        let column = Int(floor((point.x - origin) / Self.pitch)), row = Int(floor((point.y - Self.header) / Self.pitch))
        guard (0..<weeks).contains(column), (0..<7).contains(row) else { return nil }
        let date = date(column: column, row: row)
        return date <= today ? date : nil
    }
}

// MARK: - Daily tokens

private struct DailyTokensCard: View {
    let report: UsageAnalytics
    let span: RangeSpan
    let palette: ModelPalette
    @State private var selection: Date?
    private struct Point: Identifiable {
        var id: String { series + date.description }
        var date: Date, series: String, tokens: Int
    }
    private var calendar: Calendar { .current }
    private var byDay: [Date: [String: Int]] {
        var result: [Date: [String: Int]] = [:]
        for day in report.days {
            let date = calendar.startOfDay(for: day.date)
            for (name, model) in day.models where model.counts.total > 0 {
                result[date, default: [:]][palette.series(name), default: 0] += model.counts.total
            }
        }
        return result
    }
    private func points(_ byDay: [Date: [String: Int]]) -> [Point] {
        span.dates.flatMap { date -> [Point] in
            let values = byDay[date] ?? [:]
            return palette.domain.compactMap { series in values[series].map { Point(date: date, series: series, tokens: $0) } }
        }
    }
    var body: some View {
        let byDay = byDay
        let points = points(byDay)
        let selected = selection.map { calendar.startOfDay(for: $0) }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Text(L10n.tr("Daily tokens")).font(.system(size: 13, weight: .semibold))
                Spacer()
                ForEach(palette.domain, id: \.self) { series in
                    HStack(spacing: 5) {
                        Circle().fill(palette.color(series)).frame(width: 7, height: 7)
                        Text(palette.title(series)).lineLimit(1)
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(points) { point in
                    BarMark(x: .value(L10n.tr("Date"), point.date, unit: .day), y: .value("Token", point.tokens))
                        .foregroundStyle(by: .value(L10n.tr("Model"), point.series))
                        .opacity(selected == nil || selected == point.date ? 1 : 0.4)
                }
                if let selected, let values = byDay[selected] {
                    RuleMark(x: .value(L10n.tr("Date"), selected, unit: .day))
                        .foregroundStyle(Color.primary.opacity(0.15))
                        .annotation(position: .top, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltip(selected, values: values)
                        }
                }
            }
            .chartForegroundStyleScale(domain: palette.domain, range: palette.range)
            .chartLegend(.hidden)
            .chartXSelection(value: $selection)
            .chartXScale(domain: span.dates.first!...calendar.date(byAdding: .day, value: 1, to: span.dates.last!)!)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: min(8, span.dates.count))) {
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day().locale(L10n.locale), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Palette.line)
                    AxisValueLabel { if let count = value.as(Int.self) { Text(Format.tokens(count)) } }
                }
            }
            .overlay {
                if points.isEmpty {
                    Text(L10n.tr("No records in this period")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 220)
            .accessibilityLabel(L10n.tr("Daily token usage"))
        }
        .padding(20).card()
    }
    private func tooltip(_ date: Date, values: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Text(date.formatted(.dateTime.locale(L10n.locale).month(.abbreviated).day().weekday(.abbreviated)))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(Format.tokens(values.values.reduce(0, +))).fontWeight(.semibold)
            }
            ForEach(palette.domain.filter { values[$0] != nil }, id: \.self) { series in
                HStack(spacing: 6) {
                    Circle().fill(palette.color(series)).frame(width: 6, height: 6)
                    Text(palette.title(series)).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(Format.tokens(values[series] ?? 0))
                }
            }
        }
        .font(.system(size: 11)).monospacedDigit()
        .padding(.horizontal, 10).padding(.vertical, 8).frame(minWidth: 150)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.line))
    }
}

// MARK: - Hours (today)

private struct HoursCard: View {
    let report: UsageAnalytics
    var body: some View {
        let hours = report.hourTotals
        let peak = report.peakHour
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("Session start times")).font(.system(size: 13, weight: .semibold))
            Chart(0..<24, id: \.self) { hour in
                BarMark(x: .value(L10n.tr("Hour"), String(hour)), y: .value(L10n.tr("Sessions"), hours[hour]))
                    .foregroundStyle(hour == peak ? Palette.brand : Palette.brand.opacity(0.35))
                    .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: ["0", "6", "12", "18", "23"]) { value in
                    AxisValueLabel { if let hour = value.as(String.self).flatMap(Int.init) { Text(hourText(hour)) } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Palette.line)
                    AxisValueLabel()
                }
            }
            .overlay {
                if hours.allSatisfy({ $0 == 0 }) {
                    Text(L10n.tr("No records in this period")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 180)
        }
        .padding(20).card()
    }
}

// MARK: - Models

private struct ModelsCard: View {
    let report: UsageAnalytics
    let palette: ModelPalette
    var body: some View {
        let total = report.totals.total
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(L10n.tr("Model")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                Spacer()
                Text(L10n.tr("Share")).frame(width: 150, alignment: .leading)
                Text(L10n.tr("Replies")).frame(width: 64, alignment: .trailing)
                    .help(L10n.tr("Claude replies with token usage, including subagents. The total message count also includes your messages."))
                Text("Token").frame(width: 76, alignment: .trailing)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 8)
            if report.models.isEmpty {
                Text(L10n.tr("No records in this period")).font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(report.models) { model in
                Divider()
                let share = total > 0 ? Double(model.counts.total) / Double(total) : 0
                HStack(spacing: 12) {
                    Circle().fill(palette.color(model.model)).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Format.model(model.model)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(TokenKind.allCases.map { "\($0.title) \(Format.tokens($0.value(model.counts)))" }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(model.model)
                    HStack(spacing: 8) {
                        ShareBar(fraction: share, color: palette.color(model.model))
                        Text(share.formatted(.percent.precision(.fractionLength(share < 0.1 && share > 0 ? 1 : 0)).locale(L10n.locale)))
                            .foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }.frame(width: 150)
                    Text(L10n.number(model.messages)).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                    Text(Format.tokens(model.counts.total)).fontWeight(.medium).frame(width: 76, alignment: .trailing)
                }
                .font(.system(size: 12)).monospacedDigit().padding(.vertical, 11)
            }
        }
        .padding(20).card()
    }
}

private struct ShareBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(color).frame(width: max(4, proxy.size.width * min(1, fraction)))
            }
        }.frame(height: 6)
    }
}
