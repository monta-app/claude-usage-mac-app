import SwiftUI
import AppKit

struct MenuContentView: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            SectionHeader(icon: "gauge.with.needle",
                          title: "Claude Code Plans",
                          subtitle: "Subscription limits · no overage charge")
            ClaudeCodeSection()
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("Anthropic Usage")
                .font(.headline)
            Spacer()
            Button {
                Task { await store.refreshAll() }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Text("Updated \(Format.relative(store.lastUpdated))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Manage…") { openManage() }
                .buttonStyle(.borderless)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .padding(12)
    }

    private func openManage() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "manage")
    }
}

/// A distinct, tinted header used to separate the two major sections.
struct SectionHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
    }
}

struct ClaudeCodeSection: View {
    @EnvironmentObject var store: AccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            accountCard(id: AccountStore.primaryTokenID, name: store.primaryName, state: store.claudeCode)
            ForEach(store.ccAccounts) { acct in
                accountCard(id: acct.id, name: acct.name, state: store.ccStates[acct.id] ?? .loading)
            }
        }
        .padding(.top, 10)
    }

    /// Each Claude Code account rendered as a distinct card: a titled header
    /// (account name + peak-usage badge) over its limit bars.
    @ViewBuilder
    private func accountCard(id: UUID, name: String, state: ClaudeCode.State) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(name).font(.subheadline.weight(.semibold))
                Spacer()
                if let p = store.peak(of: state) {
                    Text("\(Int((p * 100).rounded()))%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(p >= 1 ? .red : (p >= 0.8 ? .orange : .green))
                }
            }
            planBlock(state: state)
            spendLine(id: id)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    /// "Spend this month: $X" — per-member Claude Code cost (notional on Max).
    @ViewBuilder
    private func spendLine(id: UUID) -> some View {
        switch store.spend[id] ?? .noConfig {
        case .amount(let usd):
            HStack {
                Text("Spend this month").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(Format.usd(usd)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        case .error(let msg):
            Text(msg).font(.caption2).foregroundStyle(.orange).lineLimit(1)
        case .loading:
            Text("Spend: loading…").font(.caption2).foregroundStyle(.secondary)
        case .noConfig:
            EmptyView()   // no admin key / email set — silent
        }
    }

    @ViewBuilder
    private func planBlock(state: ClaudeCode.State) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .loading:
                HStack { ProgressView().controlSize(.small); Text("Checking…").font(.caption) }
            case .cliMissing:
                Text("Claude Code CLI not found.")
                    .font(.caption).foregroundStyle(.secondary)
            case .stats(let cost):
                HStack {
                    Text("Total cost").font(.caption)
                    Spacer()
                    Text(Format.usd(cost)).font(.caption.monospacedDigit())
                }
                Text("Token mode — no plan limits available. Log in for limit bars.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .notLoggedIn:
                Text("Not logged in — use Manage… to log in.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .expired:
                Label("Token rejected — paste a fresh token in Manage…",
                      systemImage: "key.slash")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .rateLimited:
                Label("Throttled — will retry.", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).lineLimit(2)
            case .ok(let windows):
                ForEach(windows) { w in limitBar(w) }
            }
        }
    }

    private func limitBar(_ w: ClaudeCode.Window) -> some View {
        let color: Color = w.fraction >= 1 ? .red : (w.fraction >= 0.8 ? .orange : .green)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(w.label).font(.caption)
                Spacer()
                Text(String(format: "%.0f%%", w.fraction * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(color)
            }
            ProgressView(value: w.fraction).tint(color)
            if let reset = w.resetText {
                Text("resets \(reset)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

