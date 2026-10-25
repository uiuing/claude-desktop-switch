import SwiftUI
import SwitchCore

struct MenuCodeTasks: View {
    @Environment(AppState.self) private var state
    @State private var showsIdle = false
    var closeMenu: () -> Void = {}
    private var snapshot: CodeTaskSnapshot { state.codeTasks }
    private var ordered: [CodeTask] { state.conversationTree.mainTasks(snapshot.ordered(follows: state.library.follows)) }
    private func followed(_ task: CodeTask) -> Bool { state.follows(task.conversation) }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(L10n.tr("Claude Code tasks")).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                if snapshot.availability == .ready {
                    Text(snapshot.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }.padding(.horizontal, 14)
            if snapshot.availability != .ready {
                Label(snapshot.detail, systemImage: snapshot.availability == .switching ? "arrow.left.arrow.right" : "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14)
            }
            if !ordered.isEmpty {
                VStack(spacing: 3) {
                    group(L10n.tr("Followed conversations"), tasks: ordered.filter(followed), pinned: true)
                    let rest = ordered.filter { !followed($0) }
                    group(L10n.tr("Waiting for you"), tasks: rest.filter { $0.status.needsAttention })
                    group(L10n.tr("Running"), tasks: rest.filter { $0.status == .running })
                    group(L10n.tr("Status unknown"), tasks: rest.filter { $0.status == .unknown })
                    let idle = rest.filter { [.idle, .notRunning].contains($0.status) }
                    if !idle.isEmpty {
                        DisclosureGroup(isExpanded: $showsIdle) {
                            ForEach(idle) { row($0) }
                        } label: {
                            Text(L10n.tr("Idle conversations ({0})", idle.count.formatted(.number.locale(L10n.locale))))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 10)
                    }
                }
            } else if snapshot.availability == .ready {
                Text(L10n.tr("No running or waiting tasks")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14)
            }
        }.padding(.vertical, 3)
    }
    @ViewBuilder private func group(_ title: String, tasks: [CodeTask], pinned: Bool = false) -> some View {
        if !tasks.isEmpty {
            HStack(spacing: 4) {
                if pinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
                Text(title).font(.system(size: 10, weight: .medium))
                Spacer()
                Text(String(tasks.count)).font(.system(size: 10)).monospacedDigit()
            }.foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 4)
            ForEach(tasks) { row($0) }
        }
    }
    private func row(_ task: CodeTask) -> some View {
        Button {
            if !state.demo { closeMenu() }
            Task { await state.openCodeTask(task) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: task.status.symbol).font(.system(size: 12)).foregroundStyle(color(task.status))
                    .frame(width: 16).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.conversation.title).font(.system(size: 12, weight: .medium))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Text(task.status.title).foregroundStyle(color(task.status))
                        let count = state.conversationTree.childCount(of: task.conversation)
                        if count > 0 { Text(L10n.tr("Subtasks: {0}", L10n.argument(count))).foregroundStyle(.secondary) }
                        if let project = task.conversation.project, !project.isEmpty {
                            Text("·").foregroundStyle(.tertiary)
                            Text(URL(fileURLWithPath: project).lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.font(.system(size: 10))
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.top, 3)
            }.padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(HoverRowStyle()).padding(.horizontal, 6)
            .disabled(!state.canOpenCodeTask(task))
            .help([task.conversation.title, task.status.title, task.conversation.project,
                   L10n.tr("Open conversation in Claude")].compactMap { $0 }.joined(separator: "\n"))
            .accessibilityLabel(task.conversation.title + ", " + task.status.title)
            .accessibilityHint(L10n.tr("Open conversation in Claude"))
    }
    private func color(_ status: CodeTaskStatus) -> Color {
        status.needsAttention ? .orange : status == .running ? .green : .secondary
    }
}
