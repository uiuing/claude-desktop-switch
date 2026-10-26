import SwiftUI
import SwitchCore

struct OperationNoticeView: View {
    let message: String
    var feedback: OperationFeedback?
    var exportDiagnostics: (() -> Void)?
    var canExport = true
    let close: () -> Void
    private var color: Color {
        switch feedback?.style {
        case .success: return Palette.green
        case .warning: return .orange
        case .failure: return .red
        case nil: return Palette.brand
        }
    }
    private var symbol: String {
        switch feedback?.style {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.circle.fill"
        case nil: return "info.circle.fill"
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(color)
                .frame(width: 32, height: 32).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(feedback?.title ?? L10n.tr("Notice")).font(.system(size: 13, weight: .semibold))
                Text(feedback?.body ?? message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if feedback?.style == .failure, let exportDiagnostics {
                    Button(L10n.tr("Export diagnostics…"), action: exportDiagnostics)
                        .font(.system(size: 12)).buttonStyle(.borderless).disabled(!canExport)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(HoverRowStyle()).foregroundStyle(.secondary).hint(L10n.tr("Dismiss"))
        }
        .padding(16).frame(maxWidth: 400, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.25)))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
