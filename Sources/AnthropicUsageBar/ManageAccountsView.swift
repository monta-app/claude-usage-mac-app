import SwiftUI

struct ManageAccountsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Manage Plans")
                    .font(.title2.weight(.semibold))
                ClaudeCodeAccountsSection()
                Spacer()
            }
            .padding(20)
        }
    }
}

struct ClaudeCodeAccountsSection: View {
    @EnvironmentObject var store: AccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Code plans (Max/Pro)")
                .font(.headline)
            Text("**Primary** works with no setup — it's your current Claude Code login. To add another plan (or avoid ever being logged out), paste a **long-lived token**: click *Get token* (runs `claude setup-token` once), then paste what it prints. Tokens don't expire, so it's one-time per account. Each plan shows its real account (org · email) automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PrimaryAccountRow()
            ForEach(store.ccAccounts) { acct in
                Divider()
                CCAccountRow(account: acct)
            }

            Divider()
            Button {
                store.addCCAccount()
            } label: {
                Label("Add a plan", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// Shows "Long-lived token set" or a Get-token button + paste field.
struct TokenControls: View {
    @EnvironmentObject var store: AccountStore
    let id: UUID
    let showGetTokenHint: Bool
    @State private var pasted = ""
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.hasToken(for: id) && !editing {
                HStack(spacing: 6) {
                    Label("Long-lived token set", systemImage: "key.fill")
                        .font(.caption).foregroundStyle(.green)
                    Spacer()
                    Button("Replace") { editing = true }.buttonStyle(.borderless).font(.caption)
                    Button("Remove") { store.clearCCToken(for: id) }.buttonStyle(.borderless).font(.caption)
                }
            } else {
                HStack {
                    Button("Get token (opens Terminal)") { CCLogin.openSetupToken() }
                        .font(.caption)
                    if editing {
                        Button("Cancel") { editing = false; pasted = "" }.buttonStyle(.borderless).font(.caption)
                    }
                }
                HStack {
                    SecureField("Paste long-lived token", text: $pasted)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { store.setCCToken(pasted, for: id); pasted = ""; editing = false }
                        .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// One row per account, titled by the live CLI identity (org · email).
private struct AccountRowShell<Trailing: View>: View {
    @EnvironmentObject var store: AccountStore
    let id: UUID
    let icon: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.title(for: id)).font(.subheadline.weight(.medium))
                    if let email = store.identities[id]?.email, !email.isEmpty {
                        Text(email).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                trailing()
            }
            TokenControls(id: id, showGetTokenHint: true).padding(.leading, 24)
        }
    }
}

struct PrimaryAccountRow: View {
    @EnvironmentObject var store: AccountStore
    var body: some View {
        AccountRowShell(id: AccountStore.primaryTokenID, icon: "person.crop.circle.fill") {
            Button("Log in") { store.loginPrimary() }
                .buttonStyle(.borderless).font(.caption)
                .help("Log in / switch your default Claude Code account")
        }
    }
}

struct CCAccountRow: View {
    @EnvironmentObject var store: AccountStore
    let account: CCAccount
    var body: some View {
        AccountRowShell(id: account.id, icon: "person.crop.circle") {
            Button(role: .destructive) { store.removeCCAccount(account) } label: {
                Image(systemName: "trash")
            }.buttonStyle(.borderless)
        }
    }
}
