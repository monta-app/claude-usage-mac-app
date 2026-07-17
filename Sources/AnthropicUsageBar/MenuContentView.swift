import SwiftUI
import AppKit
import AnthropicUsageCore

struct MenuContentView: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var loginItem = LoginItem.shared
    @StateObject private var notifier = Notifier.shared
    @StateObject private var updater = UpdateChecker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.accounts.isEmpty {
                Text("No accounts yet — open Manage… and click “Add current login”.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            } else {
                ForEach(Array(store.accounts.enumerated()), id: \.element.id) { idx, acct in
                    if idx > 0 { Divider() }
                    card(acct)
                }
            }
            Divider()
            notifyRow
            loginRow
            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear { loginItem.refresh() }
    }

    private var notifyRow: some View {
        Toggle(isOn: $notifier.isEnabled) {
            Label("Notify at 100% usage", systemImage: "bell")
                .font(.caption)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var loginRow: some View {
        Toggle(isOn: Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        )) {
            Label("Launch at login", systemImage: "power")
                .font(.caption)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            }
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
                Image(systemName: "person.crop.circle.fill")
                    .font(.caption).foregroundStyle(Color.accentColor)
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
            if store.hasCredential(acct) {
                sessionControls(acct)
            }
        }
        .padding(12)
    }

    /// The "start / auto-prime the 5h window" controls — visually separated from
    /// the plan bars above so they read as account-level actions, not part of
    /// the last plan.
    @ViewBuilder
    private func sessionControls(_ acct: ConfigAccount) -> some View {
        Divider().padding(.vertical, 2)
        VStack(alignment: .leading, spacing: 6) {
            Text("SESSION")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                .kerning(0.5)
            Button {
                store.startSession(acct)
            } label: {
                if store.priming.contains(acct.id) {
                    HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Starting session…") }
                } else {
                    Label("Start 5h session now", systemImage: "play.circle")
                }
            }
            .buttonStyle(.borderless).font(.caption)
            .disabled(store.priming.contains(acct.id))
            .help("Send one tiny message to start the 5-hour window now, so it resets sooner")

            if let sch = acct.schedule, sch.enabled {
                Label("Auto-prime \(sch.startLabel)–\(sch.endLabel)\(sch.weekdaysOnly ? " · weekdays" : "")",
                      systemImage: "clock.arrow.2.circlepath")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Auto-prime off — set a daily schedule in Manage…")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
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
            if let at = w.resetAt {
                (Text("resets \(Format.clock(at)) · in ") + Text(at, style: .relative))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else if let reset = w.resetText {
                Text("resets \(reset)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Updated \(Format.relative(store.lastUpdated))").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Check for Updates…") { updater.checkNow() }
                .buttonStyle(.borderless).font(.caption)
                .help("Check GitHub for a newer build of this app")
            Button("Manage…") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "manage") }
                .buttonStyle(.borderless)
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
        }
        .padding(12)
    }
}
