import AppKit
import UniformTypeIdentifiers
import SwitchCore
import SwitchStorage

extension AppState {
    @MainActor func exportDiagnostics() async {
        guard !demo, !exportingDiagnostics else { return }
        exportingDiagnostics = true; defer { exportingDiagnostics = false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ClaudeSwitch-diagnostics.json"
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let destination = panel.url else { return }
        await RuntimeLog.shared.record(.exportStarted, component: .diagnostics)
        do {
            let data = try await RuntimeLog.shared.export()
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            await RuntimeLog.shared.record(.exportCompleted, component: .diagnostics)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            await RuntimeLog.shared.record(.failed, component: .diagnostics, level: .error, failure: RuntimeFailure(error))
            message = L10n.tr("Could not export diagnostics.")
        }
    }
}
