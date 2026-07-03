import SwiftUI
import AppKit

struct MenuContentView: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ForEach(Array(store.accounts.enumerated()), id: \.element.id) { idx, acct in
                if idx > 0 { Divider() }
                card(acct)
            }
            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Claude Usage").font(.headline)
            Spacer()
            Button { Task { await store.refresh() } } label: {
                if store.isRefreshing { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless).help("Refresh now")
        }
        .padding(12)
    }

    private func card(_ acct: ConfigAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: acct.configDir == nil ? "person.crop.circle.fill" : "person.crop.circle")
                    .font(.caption).foregroundStyle(acct.configDir == nil ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.title(for: acct)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let email = store.identities[acct.id]?.email, !email.isEmpty {
                        Text(email).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let p = store.peak(of: acct.id) {
                    Text("\(Int((p * 100).rounded()))%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(p >= 1 ? .red : (p >= 0.8 ? .orange : .green))
                }
            }
            planBlock(state: store.states[acct.id] ?? .loading)
        }
        .padding(12)
    }

    @ViewBuilder
    private func planBlock(state: ClaudeCode.State) -> some View {
        switch state {
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("Checking…").font(.caption) }
        case .cliMissing:
            Text("Claude Code CLI not found.").font(.caption).foregroundStyle(.secondary)
        case .notLoggedIn:
            Text("Not logged in — use Manage… to log in.").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .expired:
            Label("Login expired — log in again in Manage…", systemImage: "clock.arrow.circlepath")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .rateLimited:
            Label("Throttled — will retry.", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
        case .stats:
            Text("No plan limits for this login.").font(.caption).foregroundStyle(.secondary)
        case .error(let m):
            Label(m, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).lineLimit(2)
        case .ok(let windows):
            ForEach(windows) { w in limitBar(w) }
        }
    }

    private func limitBar(_ w: ClaudeCode.Window) -> some View {
        let color: Color = w.fraction >= 1 ? .red : (w.fraction >= 0.8 ? .orange : .green)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(w.label).font(.caption)
                Spacer()
                Text(String(format: "%.0f%%", w.fraction * 100)).font(.caption.monospacedDigit()).foregroundStyle(color)
            }
            ProgressView(value: w.fraction).tint(color)
            if let reset = w.resetText {
                Text("resets \(reset)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Updated \(Format.relative(store.lastUpdated))").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Manage…") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "manage") }
                .buttonStyle(.borderless)
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
        }
        .padding(12)
    }
}
