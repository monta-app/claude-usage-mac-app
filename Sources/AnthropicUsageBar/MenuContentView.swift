import SwiftUI
import AppKit

struct MenuContentView: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            activeSection
            if store.accounts.count > 1 || (store.accounts.count == 1 && store.activeID == nil) {
                Divider()
                swapSection
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

    // Active account + its plan bars.
    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill").font(.caption).foregroundStyle(.tint)
                Text(store.activeLabel).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if let p = store.peak(of: store.claudeCode) {
                    Text("\(Int((p * 100).rounded()))%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(p >= 1 ? .red : (p >= 0.8 ? .orange : .green))
                }
            }
            planBlock(state: store.claudeCode)
        }
        .padding(12)
    }

    // Quick-swap: tap any registered account to make it active.
    private var swapSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Switch account").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 8)
            ForEach(store.accounts) { acct in
                Button {
                    Task { await store.swap(to: acct) }
                } label: {
                    HStack {
                        Image(systemName: acct.id == store.activeID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(acct.id == store.activeID ? .green : .secondary)
                        Text(acct.label).font(.callout).lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12).padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .disabled(acct.id == store.activeID)
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func planBlock(state: ClaudeCode.State) -> some View {
        switch state {
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("Checking…").font(.caption) }
        case .cliMissing:
            Text("Claude Code CLI not found.").font(.caption).foregroundStyle(.secondary)
        case .notLoggedIn:
            Text("Not logged into Claude Code. Use Manage… to log in.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .expired:
            Label("Login expired — re-login in Manage…", systemImage: "clock.arrow.circlepath")
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
                Text(String(format: "%.0f%%", w.fraction * 100))
                    .font(.caption.monospacedDigit()).foregroundStyle(color)
            }
            ProgressView(value: w.fraction).tint(color)
            if let reset = w.resetText {
                Text("resets \(reset)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let s = store.status {
                Text(s).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 6)
            }
            HStack {
                Text("Updated \(Format.relative(store.lastUpdated))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Manage…") { openManage() }.buttonStyle(.borderless)
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }
            .padding(12)
        }
    }

    private func openManage() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "manage")
    }
}
