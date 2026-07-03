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
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude Code plans (Max/Pro)")
                .font(.headline)
            Text("**Primary** works with no setup (your current Claude Code login). To avoid ever being logged out — and to add a second plan — paste a **long-lived token** per account: click *Get token* (runs `claude setup-token` once), copy what it prints, paste it below. These tokens don't expire, so you do this only once per account.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PrimaryAccountRow()

            ForEach(store.ccAccounts) { acct in
                CCAccountRow(account: acct)
            }

            GroupBox("Add a plan") {
                HStack {
                    TextField("Name (e.g. Work Max)", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        store.addCCAccount(name: newName.trimmingCharacters(in: .whitespaces))
                        newName = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(6)
            }
            Text("After adding, click **Get token** on the new plan, run the login, and paste the token it prints.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Optional per-member spend config: Admin API key + member email → shows that
/// member's Claude Code cost this month (via the Claude Code Analytics API).
struct SpendControls: View {
    @EnvironmentObject var store: AccountStore
    let id: UUID
    @State private var email = ""
    @State private var key = ""

    var body: some View {
        DisclosureGroup("Show spend on top of Max (optional)") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Shows this member's extra-usage spend (the number at claude.ai/admin-settings/usage). Needs an **Analytics API key** — the org's *primary owner* creates it at claude.ai → Org settings → API — plus the member's email. Claude Enterprise (usage-based) orgs only.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("member email (e.g. you@co.com)", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .onAppear { email = store.email(for: id) }
                    Button("Save") { store.setEmail(email, for: id) }
                        .font(.caption)
                        .disabled(email.trimmingCharacters(in: .whitespaces) == store.email(for: id))
                }
                if store.hasAdminKey(for: id) {
                    HStack {
                        Label("Analytics key set", systemImage: "key.fill")
                            .font(.caption).foregroundStyle(.green)
                        Spacer()
                        Button("Remove key") { store.clearAdminKey(for: id) }
                            .buttonStyle(.borderless).font(.caption)
                    }
                } else {
                    HStack {
                        SecureField("Analytics API key", text: $key)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") { store.setAdminKey(key, for: id); key = "" }
                            .font(.caption)
                            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }
}

/// Reusable token controls: shows "Token set ✓" or a paste field + Get-token button.
struct TokenControls: View {
    @EnvironmentObject var store: AccountStore
    let id: UUID
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
                    Button("1. Get token (opens Terminal)") { CCLogin.openSetupToken() }
                        .font(.caption)
                    if editing {
                        Button("Cancel") { editing = false; pasted = "" }.buttonStyle(.borderless).font(.caption)
                    }
                }
                HStack {
                    SecureField("2. Paste long-lived token", text: $pasted)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        store.setCCToken(pasted, for: id); pasted = ""; editing = false
                    }
                    .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct PrimaryAccountRow: View {
    @EnvironmentObject var store: AccountStore
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(.tint)
                TextField("Primary", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { name = store.primaryName }
                    .onSubmit { store.renamePrimary(to: name) }
                Button("Rename") { store.renamePrimary(to: name) }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(name.trimmingCharacters(in: .whitespaces) == store.primaryName
                              || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            TokenControls(id: AccountStore.primaryTokenID)
                .padding(.leading, 24)
            SpendControls(id: AccountStore.primaryTokenID).padding(.leading, 24)
        }
    }
}

struct CCAccountRow: View {
    @EnvironmentObject var store: AccountStore
    let account: CCAccount
    @State private var name: String

    init(account: CCAccount) {
        self.account = account
        _name = State(initialValue: account.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { store.renameCCAccount(account, to: name) }
                Button("Rename") { store.renameCCAccount(account, to: name) }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(name.trimmingCharacters(in: .whitespaces) == account.name
                              || name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(role: .destructive) { store.removeCCAccount(account) } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.borderless)
            }
            TokenControls(id: account.id)
                .padding(.leading, 24)
            SpendControls(id: account.id).padding(.leading, 24)
        }
    }
}
