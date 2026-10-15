import SwiftUI
import SwitchCore

struct MenuBarTaskLabel: View {
    let snapshot: CodeTaskSnapshot
    var rotation: Double = 0
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        HStack(spacing: 5) {
            if let running = snapshot.running, let waiting = snapshot.waiting {
                Text("│").foregroundStyle(.tertiary)
                if running == 0 && waiting == 0 {
                    Image(systemName: "circle").font(.system(size: 10)); Text("0")
                } else {
                    if running > 0 {
                        Circle().trim(from: 0, to: 0.75)
                            .stroke(AngularGradient(stops: [
                                .init(color: ink.opacity(0.04), location: 0),
                                .init(color: ink.opacity(0.2), location: 0.35),
                                .init(color: ink.opacity(0.6), location: 0.7),
                                .init(color: ink, location: 1),
                            ], center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .frame(width: 12, height: 12).rotationEffect(.degrees(rotation))
                        Text(count(running))
                    }
                    if waiting > 0 {
                        Image(nsImage: glyph("hand.raised.fill", color: waitingColor)).renderingMode(.original)
                        Text(count(waiting))
                    }
                }
            }
        }.monospacedDigit().accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.tr("Claude Code tasks") + ": " + snapshot.detail)
            .help(snapshot.detail)
    }
    private func count(_ value: Int) -> String { value > 99 ? "99+" : value.formatted(.number.locale(L10n.locale)) }
    private var ink: Color { colorScheme == .dark ? .white : .black }
    private var waitingColor: NSColor {
        (colorScheme == .dark ? NSColor.white : NSColor.black).withAlphaComponent(0.8)
    }
    private func glyph(_ name: String, color: NSColor) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }
}
